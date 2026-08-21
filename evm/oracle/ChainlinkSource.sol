// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IPriceSource} from "./IPriceSource.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Chainlink as one voice among several
/// @notice A push oracle: the answer is already on chain, so this takes no
///         calldata. Its job is to normalise and to refuse a round that should
///         not count.
contract ChainlinkSource is IPriceSource {
    AggregatorV3Interface public immutable feed;
    uint8 public immutable feedDecimals;
    string private _name;

    error NoAnswer();
    error IncompleteRound();
    error StaleRound(uint80 answeredInRound, uint80 roundId);

    constructor(AggregatorV3Interface aggregator, string memory label) {
        require(address(aggregator) != address(0), "a feed at the zero address answers nothing");
        feed = aggregator;
        feedDecimals = aggregator.decimals();
        require(feedDecimals <= 18, "a feed with more than 18 decimals would lose precision here");
        _name = label;
    }

    function sourceName() external view returns (string memory) {
        return _name;
    }

    /// @param data ignored — a push oracle's answer is already on chain.
    function readPrice(bytes calldata data)
        external
        view
        returns (int256 price18, uint256 publishTime)
    {
        data; // silence the unused warning without pretending it is used

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        /**
         * Three checks Chainlink integrations routinely skip, each of which has
         * cost somebody money elsewhere.
         *
         * `updatedAt == 0` is a round that never completed. `answeredInRound <
         * roundId` means the answer is carried over from an earlier round —
         * the feed is reporting, but not reporting anything new. And a
         * non-positive answer is not a price.
         */
        if (updatedAt == 0) revert IncompleteRound();
        if (answeredInRound < roundId) revert StaleRound(answeredInRound, roundId);
        if (answer <= 0) revert NoAnswer();

        /// Scale to 18 decimals so this can be compared with a Pyth price at all.
        price18 = answer * int256(10 ** (18 - uint256(feedDecimals)));
        publishTime = updatedAt;
    }
}
