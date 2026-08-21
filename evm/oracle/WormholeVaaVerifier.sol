// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title Wormhole VAA verification, on chain
/// @notice Recovers guardian signatures over a Pyth attestation and refuses
///         anything that does not reach quorum.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
///
/// Until now this project recovered guardian signatures OFF chain, in its own
/// adapter, and signed the result. Every downstream reader was therefore
/// trusting our adapter: `ADAPTER_SIGNATURE_VERIFIED` in a case bundle meant
/// "we checked, and here is our signature saying so". That is better than
/// `ADAPTER_TLS_ONLY` and it is still a claim about us.
///
/// This removes us from that step. The chain recovers the signatures itself, so
/// a settlement conditioned on a price no longer depends on our honesty about
/// having checked it — only on the Wormhole guardian federation and on Pyth's
/// publisher aggregate, which is where the trust genuinely sits.
///
/// ── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
///
/// It verifies the ATTESTATION, not the price's relationship to reality. A
/// quorum of guardians signing a Pyth accumulator root proves the network
/// published it. It does not prove the number was right, and no signature
/// scheme could.
///
/// It also stops at the VAA. Extracting an individual price from the payload
/// means walking Pyth's Merkle profile, which is deliberately left to the
/// caller — this contract's single job is "did enough guardians sign these
/// bytes", and a contract that did two things would be harder to argue about.
contract WormholeVaaVerifier {
    /// @notice Wormhole's own quorum rule: floor(2n/3) + 1.
    /// @dev Computed, never stored. A stored quorum is a number that can drift
    ///      from the set it describes, and this one decides whether money moves.
    function quorumFor(uint256 guardianCount) public pure returns (uint256) {
        return ((guardianCount * 2) / 3) + 1;
    }

    /// @notice The pinned guardian set index. Anything else FAILS CLOSED.
    /// @dev Pinning rather than reading a registry is the deliberate choice.
    ///      Guardian-set rotation is governance data; a contract that accepted
    ///      whatever index a VAA declared would accept a set it had never been
    ///      told about. An unknown index is a verification error here, never a
    ///      silent pass — the same rule the off-chain verifier follows.
    uint32 public immutable guardianSetIndex;

    /// @notice The emitter this verifier will accept, and nothing else.
    uint16 public immutable emitterChainId;
    bytes32 public immutable emitterAddress;

    address[] private _guardians;

    error UnsupportedVersion(uint8 version);
    error UnknownGuardianSet(uint32 declared, uint32 pinned);
    error NotEnoughSignatures(uint256 provided, uint256 required);
    error GuardianIndexOutOfRange(uint8 index, uint256 setSize);
    error GuardianIndicesNotIncreasing(uint8 previous, uint8 current);
    error SignatureDoesNotRecover(uint8 guardianIndex);
    error WrongGuardian(uint8 guardianIndex, address recovered, address expected);
    error WrongEmitter(uint16 chainId, bytes32 addr);
    error Truncated();

    constructor(
        uint32 setIndex,
        address[] memory guardians,
        uint16 chainId,
        bytes32 emitter
    ) {
        require(guardians.length > 0, "a guardian set of nobody verifies nothing");
        guardianSetIndex = setIndex;
        emitterChainId = chainId;
        emitterAddress = emitter;
        for (uint256 i = 0; i < guardians.length; i++) {
            require(guardians[i] != address(0), "a zero guardian would match a failed ecrecover");
            _guardians.push(guardians[i]);
        }
    }

    function guardianCount() external view returns (uint256) {
        return _guardians.length;
    }

    function guardianAt(uint256 i) external view returns (address) {
        return _guardians[i];
    }

    function quorum() external view returns (uint256) {
        return quorumFor(_guardians.length);
    }

    struct Vaa {
        uint32 timestamp;
        uint16 emitterChain;
        bytes32 emitter;
        uint64 sequence;
        uint256 signatureCount;
        bytes payload;
    }

    /// @notice Verify a VAA and return what it attests to.
    /// @dev Reverts on anything short of a full pass. There is no boolean
    ///      "mostly verified" return: a caller that got a payload back is a
    ///      caller whose signatures checked out, so it cannot forget to look.
    function verify(bytes calldata vaa) external view returns (Vaa memory) {
        if (vaa.length < 6) revert Truncated();

        uint8 version = uint8(vaa[0]);
        if (version != 1) revert UnsupportedVersion(version);

        uint32 declaredSet = uint32(bytes4(vaa[1:5]));
        if (declaredSet != guardianSetIndex) {
            revert UnknownGuardianSet(declaredSet, guardianSetIndex);
        }

        uint256 numSignatures = uint8(vaa[5]);
        uint256 required = quorumFor(_guardians.length);
        if (numSignatures < required) revert NotEnoughSignatures(numSignatures, required);

        // Each signature is one index byte plus 65 bytes of (r, s, v).
        uint256 sigsLength = numSignatures * 66;
        if (vaa.length < 6 + sigsLength) revert Truncated();

        bytes calldata body = vaa[6 + sigsLength:];
        // Guardians sign the double keccak of the body, not the body itself.
        bytes32 digest = keccak256(abi.encodePacked(keccak256(body)));

        _checkSignatures(vaa, numSignatures, digest);

        return _readBody(body, numSignatures);
    }

    /// @dev Split out because `verify` was over the stack limit with it inline,
    ///      and splitting is better than reaching for assembly to save a slot.
    function _checkSignatures(
        bytes calldata vaa,
        uint256 numSignatures,
        bytes32 digest
    ) private view {
        /// Strictly increasing indices do the work of a seen-set without one.
        /// Wormhole emits them ordered, and requiring it makes a duplicate
        /// impossible to express — the failure that would otherwise let one
        /// guardian's signature be counted thirteen times.
        int256 previous = -1;

        for (uint256 i = 0; i < numSignatures; i++) {
            uint256 at = 6 + (i * 66);
            uint8 guardianIndex = uint8(vaa[at]);

            if (int256(uint256(guardianIndex)) <= previous) {
                revert GuardianIndicesNotIncreasing(uint8(uint256(previous)), guardianIndex);
            }
            previous = int256(uint256(guardianIndex));

            if (guardianIndex >= _guardians.length) {
                revert GuardianIndexOutOfRange(guardianIndex, _guardians.length);
            }

            bytes32 r = bytes32(vaa[at + 1:at + 33]);
            bytes32 s = bytes32(vaa[at + 33:at + 65]);
            /// Wormhole stores the recovery id as 0 or 1; ecrecover wants 27/28.
            uint8 v = uint8(vaa[at + 65]) + 27;

            address recovered = ecrecover(digest, v, r, s);
            /// ecrecover returns the zero address on failure rather than
            /// reverting. Treating that as "some guardian" is the classic way
            /// to accept a malformed signature, which is why a zero guardian is
            /// refused at construction as well.
            if (recovered == address(0)) revert SignatureDoesNotRecover(guardianIndex);

            address expected = _guardians[guardianIndex];
            if (recovered != expected) {
                revert WrongGuardian(guardianIndex, recovered, expected);
            }
        }
    }

    /// @dev Body layout: timestamp(4) nonce(4) emitterChain(2) emitter(32)
    ///      sequence(8) consistency(1) payload(...).
    function _readBody(bytes calldata body, uint256 numSignatures)
        private
        view
        returns (Vaa memory out)
    {
        if (body.length < 51) revert Truncated();

        out.timestamp = uint32(bytes4(body[0:4]));
        out.emitterChain = uint16(bytes2(body[8:10]));
        out.emitter = bytes32(body[10:42]);
        out.sequence = uint64(bytes8(body[42:50]));
        out.signatureCount = numSignatures;
        out.payload = body[51:];

        /// The emitter check is not decoration. A quorum of guardians will sign
        /// attestations from every chain Wormhole carries; without this, a
        /// perfectly valid message from an unrelated emitter would verify here
        /// and be read as a price.
        if (out.emitterChain != emitterChainId || out.emitter != emitterAddress) {
            revert WrongEmitter(out.emitterChain, out.emitter);
        }
    }
}
