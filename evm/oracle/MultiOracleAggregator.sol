// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IPriceSource} from "./IPriceSource.sol";

/// @title m-of-n independent oracles must agree, or nobody is paid
/// @notice Reads a price from several unrelated providers and settles only when
///         enough of them agree within a band the agreement committed to.
///
/// ── WHY ─────────────────────────────────────────────────────────────────────
///
/// Everything oracle-shaped here was Pyth. The chain could check that Pyth had
/// signed a number; nothing checked whether Pyth was *right*. A Pyth-wide fault
/// — a bad publisher aggregate, a compromised feed, an outage that pins a stale
/// value — was a Misharu-wide fault, and no amount of signature verification
/// fixes that.
///
/// This makes it m-of-n. Two providers that do not share infrastructure have to
/// agree before money moves.
///
/// ── AGREEMENT IS A BAND, NOT EQUALITY ───────────────────────────────────────
///
/// Two honest oracles never report the same integer. They sample different
/// venues at different instants, so "agree" has to mean "within `toleranceBps`
/// of each other" and the agreement has to commit to that number — a band
/// chosen after the prices are known is a band chosen by whoever is losing.
///
/// ── WHY IT FAILS CLOSED ─────────────────────────────────────────────────────
///
/// A median-of-three would always return something, even when all three
/// disagree wildly — it would silently pick the middle of a mess. This refuses
/// instead. The claim goes INDETERMINATE and INDETERMINATE pays nobody, which
/// is the same rule a deadlocked panel follows. Oracles disagreeing is exactly
/// the situation where guessing is worst.
///
/// ── WHAT IT DOES NOT FIX ────────────────────────────────────────────────────
///
/// Correlated failure. If every source ultimately reads the same handful of
/// exchanges, three providers agreeing is three views of one fact, and this
/// contract cannot tell that from genuine independence. Choosing sources that
/// do not share plumbing is a judgement made when the agreement is written, and
/// nothing here can make it for you.
contract MultiOracleAggregator {
    struct Source {
        IPriceSource adapter;
        string name;
    }

    Source[] private _sources;

    error NoSources();
    error WrongNumberOfInputs(uint256 given, uint256 sources);
    error NotEnoughAgreed(uint256 agreed, uint256 required, uint256 responded);
    error QuorumExceedsSources(uint256 required, uint256 sources);
    error QuorumOfZero();

    /// @notice What each source said, kept so a receipt can show the spread.
    struct Reading {
        string name;
        bool responded;
        int256 price18;
        uint256 publishTime;
        /// @notice Why it did not count, when it did not. Never silently dropped.
        string note;
    }

    struct Result {
        int256 price18;
        uint256 agreed;
        uint256 responded;
        uint256 spreadBps;
        Reading[] readings;
    }

    constructor(IPriceSource[] memory adapters) {
        if (adapters.length == 0) revert NoSources();
        for (uint256 i = 0; i < adapters.length; i++) {
            require(address(adapters[i]) != address(0), "a source at the zero address reads nothing");
            _sources.push(Source({adapter: adapters[i], name: adapters[i].sourceName()}));
        }
    }

    function sourceCount() external view returns (uint256) {
        return _sources.length;
    }

    function sourceAt(uint256 i) external view returns (address adapter, string memory name) {
        return (address(_sources[i].adapter), _sources[i].name);
    }

    /// @notice Read every source and settle if enough agree.
    /// @param perSourceData one blob per source, in the order they were registered.
    ///        Empty for a push oracle; a signed attestation for a pull oracle.
    /// @param maxAgeSeconds how old a reading may be before it stops counting
    /// @param toleranceBps how far apart two readings may be and still agree
    /// @param minAgreeing how many must agree — the m in m-of-n
    function readPrice(
        bytes[] calldata perSourceData,
        uint256 maxAgeSeconds,
        uint256 toleranceBps,
        uint256 minAgreeing
    ) external view returns (Result memory out) {
        uint256 n = _sources.length;
        if (perSourceData.length != n) revert WrongNumberOfInputs(perSourceData.length, n);
        if (minAgreeing == 0) revert QuorumOfZero();
        if (minAgreeing > n) revert QuorumExceedsSources(minAgreeing, n);

        out.readings = new Reading[](n);
        int256[] memory prices = new int256[](n);
        bool[] memory usable = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            out.readings[i].name = _sources[i].name;

            /**
             * A failing source must not take the whole read down with it.
             *
             * This is the difference between "one provider is having an outage"
             * and "no price is available". With three sources and a 2-of-3
             * quorum, one reverting adapter should be survivable — that is the
             * entire point of having more than one.
             */
            try _sources[i].adapter.readPrice(perSourceData[i]) returns (
                int256 price18, uint256 publishTime
            ) {
                out.readings[i].price18 = price18;
                out.readings[i].publishTime = publishTime;

                if (price18 <= 0) {
                    out.readings[i].note = "non-positive price";
                } else if (publishTime > block.timestamp) {
                    out.readings[i].note = "published after this block";
                } else if (block.timestamp - publishTime > maxAgeSeconds) {
                    out.readings[i].note = "too old";
                } else {
                    out.readings[i].responded = true;
                    prices[i] = price18;
                    usable[i] = true;
                    out.responded++;
                }
            } catch {
                out.readings[i].note = "the source refused or reverted";
            }
        }

        /**
         * The largest cluster of readings that agree with each other.
         *
         * Each usable reading is taken as a candidate centre and the others
         * counted against it. Picking the biggest cluster rather than, say, the
         * one containing the first source means no provider is privileged by
         * registration order.
         */
        uint256 bestCount;
        uint256 bestAt;
        for (uint256 i = 0; i < n; i++) {
            if (!usable[i]) continue;
            uint256 count;
            for (uint256 j = 0; j < n; j++) {
                if (usable[j] && _within(prices[i], prices[j], toleranceBps)) count++;
            }
            if (count > bestCount) {
                bestCount = count;
                bestAt = i;
            }
        }

        if (bestCount < minAgreeing) {
            revert NotEnoughAgreed(bestCount, minAgreeing, out.responded);
        }

        /** The median of the AGREEING set, so an outlier cannot drag the answer. */
        int256[] memory cluster = new int256[](bestCount);
        uint256 k;
        for (uint256 j = 0; j < n; j++) {
            if (usable[j] && _within(prices[bestAt], prices[j], toleranceBps)) {
                cluster[k++] = prices[j];
            }
        }
        _sortAscending(cluster);

        out.price18 = cluster.length % 2 == 1
            ? cluster[cluster.length / 2]
            : (cluster[cluster.length / 2 - 1] + cluster[cluster.length / 2]) / 2;
        out.agreed = bestCount;
        out.spreadBps = _spreadBps(cluster);
    }

    /// @dev Symmetric on purpose: measured against the larger of the two, so
    ///      "a agrees with b" and "b agrees with a" are the same statement. An
    ///      asymmetric band would make the cluster depend on which reading
    ///      happened to be the candidate centre.
    function _within(int256 a, int256 b, uint256 toleranceBps) private pure returns (bool) {
        if (a <= 0 || b <= 0) return false;
        uint256 hi = uint256(a > b ? a : b);
        uint256 lo = uint256(a > b ? b : a);
        return ((hi - lo) * 10_000) / hi <= toleranceBps;
    }

    /// @dev How far apart the agreeing readings actually were. Recorded so a
    ///      receipt can show a 2-of-3 that barely agreed differently from one
    ///      where every source matched.
    function _spreadBps(int256[] memory sorted) private pure returns (uint256) {
        if (sorted.length < 2) return 0;
        uint256 hi = uint256(sorted[sorted.length - 1]);
        uint256 lo = uint256(sorted[0]);
        return hi == 0 ? 0 : ((hi - lo) * 10_000) / hi;
    }

    /// @dev Insertion sort. The array is at most the number of registered
    ///      sources, which is a handful — a cleverer sort would cost more to
    ///      read than it saves to run.
    function _sortAscending(int256[] memory a) private pure {
        for (uint256 i = 1; i < a.length; i++) {
            int256 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = v;
        }
    }
}
