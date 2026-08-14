// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title JudgeKeyRegistry — finalizer keys with validity windows (design §27, §33.3)
/// @notice Suspend is distinct from never-registered: a suspended key stays
///         valid for verdicts finalized BEFORE the suspension time, so history
///         remains verifiable while new finalizations are blocked.
///         The owner (a timelocked multisig in production) never touches funds.
contract JudgeKeyRegistry {
    struct KeyStatus {
        uint64 activeFrom; // 0 = never registered
        uint64 suspendedAt; // 0 = not suspended
    }

    address public immutable owner;
    mapping(address => KeyStatus) public keys;

    event FinalizerAdded(address indexed finalizer, uint64 activeFrom);
    event FinalizerSuspended(address indexed finalizer, uint64 suspendedAt);

    error NotOwner();
    error AlreadyRegistered();
    error NotRegistered();

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function addFinalizer(address finalizer) external onlyOwner {
        if (keys[finalizer].activeFrom != 0) revert AlreadyRegistered();
        keys[finalizer] = KeyStatus({activeFrom: uint64(block.timestamp), suspendedAt: 0});
        emit FinalizerAdded(finalizer, uint64(block.timestamp));
    }

    function suspendFinalizer(address finalizer) external onlyOwner {
        if (keys[finalizer].activeFrom == 0) revert NotRegistered();
        keys[finalizer].suspendedAt = uint64(block.timestamp);
        emit FinalizerSuspended(finalizer, uint64(block.timestamp));
    }

    /// @notice Valid at a given decision time (design §27.5: "Judge key valid
    ///         for decision time").
    function isValidAt(address finalizer, uint64 time) external view returns (bool) {
        KeyStatus memory k = keys[finalizer];
        if (k.activeFrom == 0 || time < k.activeFrom) return false;
        if (k.suspendedAt != 0 && time >= k.suspendedAt) return false;
        return true;
    }
}
