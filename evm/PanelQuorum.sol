// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title m distinct members of a committed panel must sign
/// @notice The on-chain half of the panel feature, for EVM rails.
///
/// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
///
/// A panel decides an agreement: membership and quorum are fixed in the hash
/// both parties sign, votes are collected, and anyone can recompute the tally.
/// That is real, and on four of five rails it stopped at the receipt layer —
/// the escrow still consumed ONE finalizer signature. A 5-of-9 panel decision
/// was recorded by nine people and executed by one key.
///
/// `judge_multisig` closed that on Midnight, which is the rail with the least
/// usage. This closes it on the rail where value actually moves.
///
/// ── WHY THE PANEL IS COMMITTED, NOT LOOKED UP ───────────────────────────────
///
/// The escrow's key registry lists the PLATFORM's finalizers. A panel is not
/// that: it is whoever the two parties agreed would decide, which may be their
/// own lawyers, an industry body, or one model. Requiring panel members to also
/// be platform finalizers would quietly put us back in the middle of a decision
/// we are not party to.
///
/// So the job commits `keccak256(quorum ‖ sortedMembers)` at creation, and
/// settlement supplies the member list to be checked against it. The parties
/// choose; the chain enforces what they chose.
library PanelQuorum {
    error QuorumOfZero();
    error QuorumExceedsPanel(uint256 quorum, uint256 members);
    error PanelTooSmall(uint256 members);
    error MembersNotSorted(address previous, address current);
    error ZeroMember();
    error PanelMismatch(bytes32 supplied, bytes32 committed);
    error NotEnoughSignatures(uint256 provided, uint256 required);
    error SignatureDoesNotRecover(uint256 index);
    error SignersNotIncreasing(address previous, address current);
    error NotAPanelMember(address recovered);
    error MalleableSignature(uint256 index);

    /// @notice The commitment a job stores. Recomputable by anyone holding the panel.
    /// @dev Members must be sorted and unique, which is what makes the
    ///      commitment canonical: the same panel in a different order would
    ///      otherwise hash differently and look like a different panel.
    ///      Sorting also makes a duplicate member impossible to express, so
    ///      "one holder, two seats" cannot be committed in the first place.
    function commit(uint8 quorum, address[] memory members) internal pure returns (bytes32) {
        uint256 n = members.length;
        if (n < 2) revert PanelTooSmall(n);
        if (quorum == 0) revert QuorumOfZero();
        if (quorum > n) revert QuorumExceedsPanel(quorum, n);

        /**
         * A majority, for the same reason the off-chain rules require one: at
         * 2-of-4 two members can vote to release while two vote to refund and
         * both thresholds are met at once, so the outcome would depend on which
         * settlement transaction landed first. Two disjoint majorities cannot
         * exist.
         */
        if (uint256(quorum) * 2 <= n) revert QuorumExceedsPanel(quorum, n);

        address previous = address(0);
        for (uint256 i = 0; i < n; i++) {
            if (members[i] == address(0)) revert ZeroMember();
            if (members[i] <= previous) revert MembersNotSorted(previous, members[i]);
            previous = members[i];
        }
        return keccak256(abi.encode(quorum, members));
    }

    /// @notice Check that `quorum` distinct committed members signed `digest`.
    /// @param committed the commitment stored on the job at creation
    /// @param quorum how many must sign
    /// @param members the full panel, sorted — checked against `committed`
    /// @param signatures at least `quorum` of them, ordered by recovered address
    /// @return signers the addresses that signed, in ascending order
    function verify(
        bytes32 committed,
        uint8 quorum,
        address[] memory members,
        bytes[] memory signatures,
        bytes32 digest
    ) internal pure returns (address[] memory signers) {
        /**
         * The panel is recomputed and compared BEFORE anything else.
         *
         * Without this the caller could supply a panel of their own choosing —
         * every signature would verify against it perfectly, and the settlement
         * would be authorised by people the agreement never named. It is the
         * whole reason the commitment exists.
         */
        bytes32 supplied = commit(quorum, members);
        if (supplied != committed) revert PanelMismatch(supplied, committed);

        if (signatures.length < quorum) revert NotEnoughSignatures(signatures.length, quorum);

        signers = new address[](signatures.length);
        address previous = address(0);

        for (uint256 i = 0; i < signatures.length; i++) {
            address recovered = _recover(digest, signatures[i], i);

            /**
             * Strictly increasing recovered addresses do the work of a seen-set
             * without one, and make a repeated signer unrepresentable rather
             * than merely detected — the failure that turns 5-of-9 into 1-of-9.
             */
            if (recovered <= previous) revert SignersNotIncreasing(previous, recovered);
            previous = recovered;

            if (!_isMember(members, recovered)) revert NotAPanelMember(recovered);
            signers[i] = recovered;
        }
    }

    function _recover(bytes32 digest, bytes memory signature, uint256 index)
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
         * Reject the high-s half. secp256k1 signatures are malleable — (r, s)
         * and (r, n−s) both recover the same address — so one member's approval
         * could otherwise be resubmitted in a second form. The ascending-address
         * check would still catch it here, but a caller deduplicating on
         * signature BYTES elsewhere would see two distinct approvals from one
         * member, and that is exactly the confusion worth refusing at source.
         */
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert MalleableSignature(index);
        }

        address recovered = ecrecover(digest, v, r, s);
        /// ecrecover answers with the zero address on failure rather than
        /// reverting, which is why a zero member is refused at commit time too.
        if (recovered == address(0)) revert SignatureDoesNotRecover(index);
        return recovered;
    }

    /// @dev Linear over a panel bounded at nine. A mapping would cost storage
    ///      to save a loop nobody notices.
    function _isMember(address[] memory members, address who) private pure returns (bool) {
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == who) return true;
        }
        return false;
    }
}
