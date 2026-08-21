// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IPriceSource} from "./IPriceSource.sol";

interface IApi3Proxy {
    /// @dev API3 reads return a signed 224-bit value at 18 decimals already.
    function read() external view returns (int224 value, uint32 timestamp);
    function dapiName() external view returns (bytes32);
}

/// @title API3 as one voice among several
/// @notice A third lineage, deliberately. Pyth aggregates publishers on its own
///         chain and attests over Wormhole; Chainlink runs a decentralised
///         oracle network reporting to an on-chain aggregator; API3 has the
///         data providers sign their OWN data, with no third-party node layer
///         in between.
///
///         Three sources that share plumbing are one source wearing three
///         labels, so what matters is not the count but that the failure modes
///         are genuinely different.
///
/// @dev API3 already reports at 18 decimals, so no rescaling is needed — which
///      is exactly why the interface fixes 18 rather than letting each adapter
///      pick. The one that needs no conversion is the one that would silently
///      be wrong if the convention were "whatever the provider uses".
contract Api3Source is IPriceSource {
    IApi3Proxy public immutable proxy;
    string private _name;

    error NoAnswer();
    error NoTimestamp();

    constructor(IApi3Proxy dapiProxy, string memory label) {
        require(address(dapiProxy) != address(0), "a proxy at the zero address reads nothing");
        proxy = dapiProxy;
        _name = label;
    }

    function sourceName() external view returns (string memory) {
        return _name;
    }

    /// @notice The dAPI this proxy is pointed at, so a receipt can name the feed.
    function dapiName() external view returns (bytes32) {
        return proxy.dapiName();
    }

    /// @param data ignored — API3 pushes its answer on chain.
    function readPrice(bytes calldata data)
        external
        view
        returns (int256 price18, uint256 publishTime)
    {
        data;

        (int224 value, uint32 timestamp) = proxy.read();

        /**
         * Reverting rather than returning a sentinel, because the aggregator
         * counts a returned zero as a vote for zero. A source that fails must
         * be absent from the vote, not present with a wrong opinion.
         */
        if (timestamp == 0) revert NoTimestamp();
        if (value <= 0) revert NoAnswer();

        /**
         * NOT rejected here: an old timestamp.
         *
         * Freshness belongs to the aggregator, which knows what the agreement
         * committed to. This adapter reports what the feed says and when it
         * said it; deciding that 56 days is too old is not an adapter's call to
         * make, and making it here would hide the reading from the receipt
         * instead of showing it excluded and named.
         */
        price18 = int256(value);
        publishTime = timestamp;
    }
}
