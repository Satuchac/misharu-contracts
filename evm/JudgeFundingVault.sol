// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

interface IERC20Vault {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title JudgeFundingVault — evaluation-cost deposits (design §27.8)
/// @notice Judging costs money whatever the outcome. If that cost is not
///         secured before work starts, a case can reach the judge with no way
///         to pay for the evaluation — and an unpayable judge is an unjudgeable
///         case, which silently becomes an INDETERMINATE freeze. This vault
///         removes that failure mode: the buyer locks the committed maximum
///         evaluation cost up front, the operator can only ever claim what was
///         actually spent (bounded by that maximum), and the remainder returns
///         to the depositor.
///
/// Deliberately separate from the escrow so evaluation money can never mingle
/// with principal or corrupt the allocation-sum invariant (§27.8).
///
/// Invariants:
/// - claimed + refunded <= deposited, per job, always;
/// - only the registered operator may claim, and never more than the deposit;
/// - the depositor can always recover the unclaimed remainder after the
///   refund deadline, and that path cannot be blocked by anyone.
contract JudgeFundingVault {
    struct Deposit {
        address depositor;
        uint256 amount;
        uint256 claimed;
        uint64 refundableAfter;
        bool closed;
        // The split in force when this money was committed. Locked here so a
        // later fee change cannot reach back into an agreement already funded.
        uint16 feeBps;
    }

    IERC20Vault public immutable token;
    address public immutable operator;   // claims actual evaluation costs
    address public immutable guardian;   // may pause new deposits only

    mapping(bytes32 => Deposit) public deposits; // key: keccak(escrow, jobId)
    bool public paused;
    uint256 private lock = 1;

    event Deposited(bytes32 indexed key, address indexed depositor, uint256 amount, uint64 refundableAfter);
    event Claimed(bytes32 indexed key, uint256 amount, string reason);
    event ClaimedForJudge(
        bytes32 indexed key, address indexed judge, uint256 toJudge, uint256 toPlatform, string reason
    );
    event Refunded(bytes32 indexed key, address indexed to, uint256 amount);
    event PauseSet(bool paused);
    event PlatformFeeSet(uint16 bps);
    event PlatformFeeProposed(uint16 bps, uint64 effectiveAt);

    error NotOperator();
    error NotGuardian();
    error NotDepositor();
    error AlreadyExists();
    error NoDeposit();
    error Closed();
    error ExceedsDeposit();
    error TooEarly();
    error TransferFailed();
    error Paused_();
    error Reentrancy();
    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh();
    error NoPendingFee();

    /// @notice Platform share of an evaluation fee, in basis points.
    /// @dev Settable by the operator, under three constraints that keep it a
    ///      guarantee rather than a promise:
    ///        1. it can never exceed MAX_PLATFORM_FEE_BPS, which IS immutable;
    ///        2. raising it takes effect only after FEE_TIMELOCK, announced
    ///           on-chain, so judges and buyers can see it coming and leave;
    ///        3. every deposit records the rate in force when it was made, so a
    ///           change can never alter the split of money already committed.
    ///      Lowering is immediate — there is nobody to protect from a cut.
    uint16 public platformFeeBps;
    uint16 public constant MAX_PLATFORM_FEE_BPS = 2000;
    uint64 public constant FEE_TIMELOCK = 7 days;
    uint16 public pendingFeeBps;
    uint64 public pendingFeeEffectiveAt;

    constructor(IERC20Vault token_, address operator_, address guardian_, uint16 platformFeeBps_) {
        if (platformFeeBps_ > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        token = token_;
        operator = operator_;
        guardian = guardian_;
        platformFeeBps = platformFeeBps_;
    }

    /// @notice How an evaluation fee divides. Public so a judge can verify what
    ///         it will actually receive before agreeing to serve a panel.
    function splitOf(uint256 amount) public view returns (uint256 toJudge, uint256 toPlatform) {
        return splitAt(amount, platformFeeBps);
    }

    /// @notice The split a specific job will actually get, at its locked rate.
    function splitOfJob(address escrow, uint256 jobId, uint256 amount)
        public view returns (uint256 toJudge, uint256 toPlatform)
    {
        return splitAt(amount, deposits[key(escrow, jobId)].feeBps);
    }

    function splitAt(uint256 amount, uint16 bps) internal pure returns (uint256 toJudge, uint256 toPlatform) {
        toPlatform = (amount * bps) / 10_000;
        toJudge = amount - toPlatform;
    }

    /// @notice Operator sets the platform share. A cut applies at once; a rise
    ///         is queued for FEE_TIMELOCK so nobody is repriced without notice.
    function setPlatformFee(uint16 bps) external {
        if (msg.sender != operator) revert NotOperator();
        if (bps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        if (bps <= platformFeeBps) {
            platformFeeBps = bps;
            pendingFeeBps = 0;
            pendingFeeEffectiveAt = 0;
            emit PlatformFeeSet(bps);
        } else {
            pendingFeeBps = bps;
            pendingFeeEffectiveAt = uint64(block.timestamp) + FEE_TIMELOCK;
            emit PlatformFeeProposed(bps, pendingFeeEffectiveAt);
        }
    }

    /// @notice Activate a queued rise once its timelock has run. Callable by
    ///         anyone: the delay is the protection, not the caller.
    function applyPlatformFee() external {
        if (pendingFeeEffectiveAt == 0) revert NoPendingFee();
        if (block.timestamp < pendingFeeEffectiveAt) revert TooEarly();
        platformFeeBps = pendingFeeBps;
        emit PlatformFeeSet(pendingFeeBps);
        pendingFeeBps = 0;
        pendingFeeEffectiveAt = 0;
    }

    modifier nonReentrant() {
        if (lock != 1) revert Reentrancy();
        lock = 2;
        _;
        lock = 1;
    }

    function key(address escrow, uint256 jobId) public pure returns (bytes32) {
        return keccak256(abi.encode(escrow, jobId));
    }

    /// @notice Lock the committed maximum evaluation cost for a job. Must be
    ///         done before the job is funded; the off-chain manifest validator
    ///         refuses to let funding proceed without a sufficient deposit.
    function deposit(address escrow, uint256 jobId, uint256 amount, uint64 refundableAfter)
        external
        nonReentrant
    {
        if (paused) revert Paused_();
        if (amount == 0) revert ZeroAmount();
        bytes32 k = key(escrow, jobId);
        if (deposits[k].amount != 0) revert AlreadyExists();
        deposits[k] = Deposit({
            depositor: msg.sender,
            amount: amount,
            claimed: 0,
            refundableAfter: refundableAfter,
            closed: false,
            feeBps: platformFeeBps
        });
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(k, msg.sender, amount, refundableAfter);
    }

    /// @notice Operator claims the evaluation cost actually incurred. Bounded
    ///         by the deposit, so a buyer's exposure is exactly what was
    ///         committed in the manifest — never more.
    function claim(address escrow, uint256 jobId, uint256 amount, string calldata reason)
        external
        nonReentrant
    {
        if (msg.sender != operator) revert NotOperator();
        bytes32 k = key(escrow, jobId);
        Deposit storage d = deposits[k];
        if (d.amount == 0) revert NoDeposit();
        if (d.closed) revert Closed();
        if (d.claimed + amount > d.amount) revert ExceedsDeposit();
        d.claimed += amount;
        if (!token.transfer(operator, amount)) revert TransferFailed();
        emit Claimed(k, amount, reason);
    }

    /// @notice Pay a third-party judge for an evaluation, retaining the platform
    ///         share. Same deposit bound as `claim`: the buyer's exposure is
    ///         exactly what was committed, however the fee is divided.
    /// @dev The judge is paid DIRECTLY. The operator authorises the claim because
    ///      it is the party that saw the attestation, but the money does not pass
    ///      through the operator's balance on its way.
    function claimForJudge(
        address escrow,
        uint256 jobId,
        uint256 amount,
        address judge,
        string calldata reason
    ) external nonReentrant {
        if (msg.sender != operator) revert NotOperator();
        if (judge == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        bytes32 k = key(escrow, jobId);
        Deposit storage d = deposits[k];
        if (d.amount == 0) revert NoDeposit();
        if (d.closed) revert Closed();
        if (d.claimed + amount > d.amount) revert ExceedsDeposit();

        // The rate locked when this job was funded, not the rate today.
        (uint256 toJudge, uint256 toPlatform) = splitAt(amount, d.feeBps);
        d.claimed += amount;
        if (!token.transfer(judge, toJudge)) revert TransferFailed();
        if (toPlatform > 0 && !token.transfer(operator, toPlatform)) revert TransferFailed();
        emit ClaimedForJudge(k, judge, toJudge, toPlatform, reason);
    }

    /// @notice Return the unclaimed remainder to the depositor. Callable by the
    ///         depositor after the refund deadline, or by the operator at any
    ///         time (to settle a case early). Never blocked by pause.
    function refund(address escrow, uint256 jobId) external nonReentrant {
        bytes32 k = key(escrow, jobId);
        Deposit storage d = deposits[k];
        if (d.amount == 0) revert NoDeposit();
        if (d.closed) revert Closed();
        if (msg.sender != operator) {
            if (msg.sender != d.depositor) revert NotDepositor();
            if (block.timestamp < d.refundableAfter) revert TooEarly();
        }
        uint256 remainder = d.amount - d.claimed;
        d.closed = true;
        if (remainder > 0) {
            if (!token.transfer(d.depositor, remainder)) revert TransferFailed();
        }
        emit Refunded(k, d.depositor, remainder);
    }

    /// @notice Is this job's evaluation funded to at least `required`?
    ///         The orchestrator checks this before scheduling any judge run.
    function isFunded(address escrow, uint256 jobId, uint256 required) external view returns (bool) {
        Deposit storage d = deposits[key(escrow, jobId)];
        return !d.closed && (d.amount - d.claimed) >= required;
    }

    function available(address escrow, uint256 jobId) external view returns (uint256) {
        Deposit storage d = deposits[key(escrow, jobId)];
        if (d.closed) return 0;
        return d.amount - d.claimed;
    }

    /// @notice Pause blocks NEW deposits only. Claims and refunds always work,
    ///         so locked evaluation budget can never be trapped.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = paused_;
        emit PauseSet(paused_);
    }
}
