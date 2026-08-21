// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title One price source, normalised
/// @notice Every provider reports differently — Pyth carries a signed
///         attestation in calldata and a base-10 exponent, Chainlink keeps a
///         pushed answer on chain with its own decimals. This is the shape they
///         are made to share so the aggregator can compare them at all.
///
/// @dev Prices are normalised to **18 decimals**, always. Comparing a
///      Chainlink 8-decimal answer against a Pyth 8-decimal-exponent price by
///      raw integer would make two agreeing oracles look wildly apart, and the
///      band check downstream would either reject everything or — worse, if the
///      scales happened to differ by a factor the band tolerated — accept a
///      disagreement as agreement.
interface IPriceSource {
    /// @notice A human label, so a receipt names the provider rather than an address.
    function sourceName() external view returns (string memory);

    /// @param data provider-specific input. Empty for a push oracle whose answer
    ///             is already on chain; a signed attestation for a pull oracle.
    /// @return price18 the price scaled to 18 decimals
    /// @return publishTime when the provider says it was observed
    /// @dev MUST revert rather than return a sentinel. A source that returns
    ///      zero on failure would be counted as a vote for zero, and a cluster
    ///      of failing sources would agree with each other perfectly.
    function readPrice(bytes calldata data)
        external
        view
        returns (int256 price18, uint256 publishTime);
}
