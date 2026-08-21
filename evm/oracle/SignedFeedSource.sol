// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IPriceSource} from "./IPriceSource.sol";

/// @title A first-party API provider as a voting source
/// @notice For data that comes from whoever actually observed it — an exchange
///         signing its own trades, a market maker signing its own book — rather
///         than from an oracle network relaying somebody else's numbers.
///
/// ── WHY THIS SHAPE, AND NOT "CALL AN API" ───────────────────────────────────
///
/// A contract cannot make an HTTP request, so every "API oracle" is really
/// somebody putting the answer on chain. The only question is who you have to
/// trust to have done it faithfully. If a relayer submits a number and the
/// contract believes it, the relayer IS the oracle and the API is decoration.
///
/// So the provider signs. The chain verifies the signature against a pinned
/// key, and the relayer becomes a courier who cannot alter what they carry.
/// That is the same construction as the Wormhole guardian check, applied to a
/// commercial data feed.
///
/// ── WHY m-of-n WITHIN A SINGLE SOURCE ───────────────────────────────────────
///
/// One signer is one key on one machine. Requiring m of n reporters makes a
/// single compromised key insufficient, exactly as it does at the panel layer.
/// It is deliberately independent of the aggregator's own m-of-n: this is
/// "how sure are we that THIS provider said it", and that is "how many
/// providers agree".
///
/// ── THE THING THAT MUST NOT BE FORGOTTEN ────────────────────────────────────
///
/// A provider whose data is derived from Pyth or Chainlink is NOT an
/// independent source, however impeccably it signs. It would add a signature
/// and no information, while looking on chain exactly like genuine diversity.
/// Nothing in this contract can detect that; it is a judgement made when the
/// signer set is chosen, and `MultiOracleAggregator` says the same about its
/// own source list.
contract SignedFeedSource is IPriceSource {
    /// @notice What a reporter signs. Every field is here to stop a replay.
    /// @dev The chain id and this contract's address are in the digest, so a
    ///      signature cannot be lifted to another chain or another deployment.
    ///      The feed id stops an ETH/USD quote being replayed as BTC/USD, and
    ///      the timestamp stops an old quote being resubmitted as current.
    bytes32 public constant TYPEHASH =
        keccak256("MisharuPrice(bytes32 feedId,int256 price18,uint256 publishTime)");

    bytes32 public immutable feedId;
    uint256 public immutable requiredSigners;
    string private _name;

    address[] private _reporters;

    error NotEnoughSigners(uint256 provided, uint256 required);
    error SignatureDoesNotRecover(uint256 index);
    error NotAReporter(address recovered);
    error SignersNotIncreasing(address previous, address current);
    error NoAnswer();

    constructor(
        bytes32 feed,
        address[] memory reporters,
        uint256 required,
        string memory label
    ) {
        require(reporters.length > 0, "a source with no reporters reports nothing");
        require(required > 0, "a threshold of zero would accept anything");
        require(required <= reporters.length, "a threshold above the reporter count can never be met");
        feedId = feed;
        requiredSigners = required;
        _name = label;
        for (uint256 i = 0; i < reporters.length; i++) {
            require(reporters[i] != address(0), "a zero reporter would match a failed ecrecover");
            _reporters.push(reporters[i]);
        }
    }

    function sourceName() external view returns (string memory) {
        return _name;
    }

    function reporterCount() external view returns (uint256) {
        return _reporters.length;
    }

    function reporterAt(uint256 i) external view returns (address) {
        return _reporters[i];
    }

    /// @notice The exact digest a reporter must sign.
    /// @dev Served so a provider never has to reconstruct it and cannot be
    ///      induced to sign something adjacent to it.
    function digest(int256 price18, uint256 publishTime) public view returns (bytes32) {
        return keccak256(
            abi.encode(TYPEHASH, block.chainid, address(this), feedId, price18, publishTime)
        );
    }

    /// @param data abi-encoded (int256 price18, uint256 publishTime, bytes[] signatures)
    function readPrice(bytes calldata data)
        external
        view
        returns (int256 price18, uint256 publishTime)
    {
        bytes[] memory signatures;
        (price18, publishTime, signatures) = abi.decode(data, (int256, uint256, bytes[]));

        if (price18 <= 0) revert NoAnswer();
        if (signatures.length < requiredSigners) {
            revert NotEnoughSigners(signatures.length, requiredSigners);
        }

        bytes32 d = digest(price18, publishTime);

        /**
         * Ascending recovered addresses do the work of a seen-set without one,
         * and make a repeated signature unrepresentable rather than merely
         * detected — the failure that turns 3-of-5 into 1-of-5.
         */
        address previous = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address recovered = _recover(d, signatures[i], i);
            if (recovered <= previous) revert SignersNotIncreasing(previous, recovered);
            previous = recovered;
            if (!_isReporter(recovered)) revert NotAReporter(recovered);
        }
    }

    function _recover(bytes32 d, bytes memory signature, uint256 index)
        private
        pure
        returns (address)
    {
        if (signature.length != 65) revert SignatureDoesNotRecover(index);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (v < 27) v += 27;

        /**
         * Reject the high-s half of every signature.
         *
         * secp256k1 signatures are malleable: (r, s) and (r, n-s) both verify
         * and recover the same address. Left alone, one reporter's quote could
         * be resubmitted in a second form — passing the ascending-address check
         * is not the issue, but any caller deduplicating on signature BYTES
         * would see two distinct signatures from one reporter.
         */
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert SignatureDoesNotRecover(index);
        }

        address recovered = ecrecover(d, v, r, s);
        /// ecrecover answers with the zero address on failure rather than reverting.
        if (recovered == address(0)) revert SignatureDoesNotRecover(index);
        return recovered;
    }

    function _isReporter(address who) private view returns (bool) {
        for (uint256 i = 0; i < _reporters.length; i++) {
            if (_reporters[i] == who) return true;
        }
        return false;
    }
}
