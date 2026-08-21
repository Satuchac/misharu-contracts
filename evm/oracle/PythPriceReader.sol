// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {WormholeVaaVerifier} from "./WormholeVaaVerifier.sol";

/// @title Read a Pyth price from an attestation, on chain
/// @notice Verifies the guardians signed it, proves the price message is inside
///         the signed Merkle root, and applies the freshness and confidence
///         policy — all without trusting whoever submitted it.
///
/// ── THE GAP THIS CLOSES ─────────────────────────────────────────────────────
///
/// `WormholeVaaVerifier` answers "did enough guardians sign these bytes". That
/// removed our adapter from the SIGNATURE check and left something behind that
/// is easy to miss: the price itself was still a number our adapter pulled out
/// of the payload and told you about.
///
/// So a dishonest adapter could take a genuine, fully verified attestation and
/// report a different price than the one inside it. Every signature check would
/// pass. The gap was narrower than before and it was still there.
///
/// This closes it. The number comes out of the signed Merkle root, on chain,
/// via an inclusion proof. Nobody has to be believed about what the attestation
/// said.
///
/// ── THE POLICY IS ON CHAIN TOO, AND THAT IS THE POINT ───────────────────────
///
/// Staleness and confidence used to be checked by `checkObservation` in our
/// adapter. A price that was hours old, or one Pyth itself was unsure about,
/// was refused by us — which is to say, refused by the party who benefits from
/// being trusted. Both are enforced here instead, so a settlement cannot use a
/// stale or wide-confidence price even if our adapter would have allowed it.
contract PythPriceReader {
    WormholeVaaVerifier public immutable vaaVerifier;

    error BadAccumulatorMagic(bytes4 found);
    error UnsupportedUpdateType(uint8 found);
    error PayloadTooShort();
    error MessageTooShort();
    error NotInMerkleRoot();
    error WrongFeed(bytes32 found, bytes32 wanted);
    error UnsupportedMessageType(uint8 found);
    error TooOld(uint256 publishTime, uint256 nowSeconds, uint256 maxAgeSeconds);
    error PublishedInTheFuture(uint256 publishTime, uint256 nowSeconds);
    error ConfidenceTooWide(uint256 ratioBps, uint256 maxBps);
    error NonPositivePrice(int64 price);

    /// @dev "AUWV" — the accumulator update payload the VAA carries.
    bytes4 private constant AUWV = 0x41555756;

    struct Price {
        bytes32 feedId;
        int64 price;
        uint64 conf;
        int32 expo;
        uint64 publishTime;
        /// @notice conf/price in basis points. The width Pyth itself reports.
        uint256 confidenceRatioBps;
        /// @notice The 20-byte keccak160 root the guardians signed.
        bytes20 merkleRoot;
    }

    constructor(WormholeVaaVerifier verifier) {
        require(address(verifier) != address(0), "a reader with no verifier verifies nothing");
        vaaVerifier = verifier;
    }

    /// @notice Verify an attestation and return the price it actually contains.
    /// @param vaa            the Wormhole VAA, as emitted by Pyth
    /// @param message        the price-feed message claimed to be in the root
    /// @param proof          its keccak160 Merkle inclusion proof
    /// @param wantedFeed     which feed the caller asked for
    /// @param maxAgeSeconds  how old the price may be
    /// @param maxConfBps     how wide Pyth's own confidence may be
    /// @dev Reverts on anything short of a full pass. A caller holding a Price
    ///      is a caller whose attestation verified, whose message was inside the
    ///      signed root, and whose policy was met — so it cannot forget to check.
    function readPrice(
        bytes calldata vaa,
        bytes calldata message,
        bytes20[] calldata proof,
        bytes32 wantedFeed,
        uint256 maxAgeSeconds,
        uint256 maxConfBps
    ) external view returns (Price memory out) {
        /// The guardians first. Everything below is meaningless without it.
        WormholeVaaVerifier.Vaa memory attested = vaaVerifier.verify(vaa);

        out.merkleRoot = _rootFrom(attested.payload);

        /// The message must be inside the root the guardians signed. This is
        /// the step that stops a genuine attestation being paired with a price
        /// that was never in it.
        if (!_proves(message, proof, out.merkleRoot)) revert NotInMerkleRoot();

        _readMessage(message, out);

        if (out.feedId != wantedFeed) revert WrongFeed(out.feedId, wantedFeed);

        _applyPolicy(out, maxAgeSeconds, maxConfBps);
    }

    /// @dev AUWV payload: magic(4) type(1) slot(8) ringSize(4) root(20).
    function _rootFrom(bytes memory payload) private pure returns (bytes20) {
        if (payload.length < 37) revert PayloadTooShort();
        bytes4 magic = bytes4(_slice32(payload, 0));
        if (magic != AUWV) revert BadAccumulatorMagic(magic);
        uint8 updateType = uint8(payload[4]);
        if (updateType != 0) revert UnsupportedUpdateType(updateType);

        bytes20 root;
        // Root sits at offset 17, after magic(4) type(1) slot(8) ringSize(4).
        assembly ("memory-safe") {
            root := mload(add(add(payload, 0x20), 17))
        }
        return root;
    }

    /// @dev Pyth's Merkle profile: keccak160, leaf 0x00, node 0x01 over children
    ///      sorted lexicographically. Sorting is why a proof carries no side
    ///      bits — and why the implementation must sort rather than assume.
    function _proves(bytes calldata message, bytes20[] calldata proof, bytes20 root)
        private
        pure
        returns (bool)
    {
        bytes20 current = bytes20(keccak256(abi.encodePacked(uint8(0x00), message)));
        for (uint256 i = 0; i < proof.length; i++) {
            bytes20 sibling = proof[i];
            (bytes20 a, bytes20 b) = current <= sibling ? (current, sibling) : (sibling, current);
            current = bytes20(keccak256(abi.encodePacked(uint8(0x01), a, b)));
        }
        return current == root;
    }

    /// @dev PriceFeed message: type(1) feedId(32) price(i64) conf(u64) expo(i32)
    ///      publishTime(i64) prevPublishTime(i64) emaPrice(i64) emaConf(u64).
    function _readMessage(bytes calldata message, Price memory out) private pure {
        if (message.length < 85) revert MessageTooShort();
        uint8 messageType = uint8(message[0]);
        if (messageType != 0) revert UnsupportedMessageType(messageType);

        out.feedId = bytes32(message[1:33]);
        /// Signed fields are two's complement big-endian; the cast through the
        /// unsigned type is what preserves a negative price rather than
        /// wrapping it into something enormous.
        out.price = int64(uint64(bytes8(message[33:41])));
        out.conf = uint64(bytes8(message[41:49]));
        out.expo = int32(uint32(bytes4(message[49:53])));
        out.publishTime = uint64(bytes8(message[53:61]));
    }

    /// @dev The admission policy that used to live in our adapter.
    function _applyPolicy(Price memory out, uint256 maxAgeSeconds, uint256 maxConfBps)
        private
        view
    {
        /// A non-positive price is not a price. Pyth can publish one during an
        /// outage, and letting it through would make every ">= threshold"
        /// comparison below it trivially false in a way nobody intended.
        if (out.price <= 0) revert NonPositivePrice(out.price);

        /// Published ahead of the block is a clock disagreement, not a fresh
        /// price. Treating it as fresh would make a future-dated attestation
        /// the freshest thing available, forever.
        if (out.publishTime > block.timestamp) {
            revert PublishedInTheFuture(out.publishTime, block.timestamp);
        }
        uint256 age = block.timestamp - out.publishTime;
        if (age > maxAgeSeconds) revert TooOld(out.publishTime, block.timestamp, maxAgeSeconds);

        /// Pyth's own uncertainty. A price the publisher aggregate is unsure
        /// about should not move money, and how unsure is too unsure belongs to
        /// the agreement rather than to us.
        out.confidenceRatioBps = (uint256(out.conf) * 10_000) / uint256(uint64(out.price));
        if (out.confidenceRatioBps > maxConfBps) {
            revert ConfidenceTooWide(out.confidenceRatioBps, maxConfBps);
        }
    }

    function _slice32(bytes memory b, uint256 at) private pure returns (bytes32 out) {
        assembly ("memory-safe") {
            out := mload(add(add(b, 0x20), at))
        }
    }
}
