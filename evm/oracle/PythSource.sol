// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IPriceSource} from "./IPriceSource.sol";
import {PythPriceReader} from "./PythPriceReader.sol";

/// @title Pyth as one voice among several
/// @notice A pull oracle: the attestation arrives in calldata and is verified
///         here — guardian signatures, Merkle inclusion, the lot — before its
///         number is allowed to vote.
contract PythSource is IPriceSource {
    PythPriceReader public immutable reader;
    bytes32 public immutable feedId;
    string private _name;

    /// @dev The aggregator applies its own age and agreement rules, so this
    ///      passes bounds wide enough not to pre-empt them. Narrowing here as
    ///      well would mean two places deciding the same thing, and the one
    ///      nobody was looking at would eventually win.
    uint256 private constant WIDE_AGE = 365 days;
    uint256 private constant WIDE_CONF = 10_000;

    constructor(PythPriceReader priceReader, bytes32 feed, string memory label) {
        require(address(priceReader) != address(0), "a source with no reader reads nothing");
        reader = priceReader;
        feedId = feed;
        _name = label;
    }

    function sourceName() external view returns (string memory) {
        return _name;
    }

    /// @param data abi-encoded (bytes vaa, bytes message, bytes20[] proof)
    function readPrice(bytes calldata data)
        external
        view
        returns (int256 price18, uint256 publishTime)
    {
        (bytes memory vaa, bytes memory message, bytes20[] memory proof) =
            abi.decode(data, (bytes, bytes, bytes20[]));

        PythPriceReader.Price memory p =
            reader.readPrice(vaa, message, proof, feedId, WIDE_AGE, WIDE_CONF);

        /**
         * Pyth reports a base-10 exponent, almost always negative. Normalising
         * to 18 decimals is what makes this comparable to a Chainlink answer;
         * without it two agreeing oracles would look orders of magnitude apart.
         */
        int256 exponent = int256(p.expo);
        require(exponent >= -18 && exponent <= 18, "a Pyth exponent outside +/-18 does not fit this scale");

        price18 = exponent >= 0
            ? int256(p.price) * int256(10 ** uint256(18 + uint256(int256(exponent))))
            : int256(p.price) * int256(10 ** uint256(18 - uint256(int256(-exponent))));
        publishTime = p.publishTime;
    }
}
