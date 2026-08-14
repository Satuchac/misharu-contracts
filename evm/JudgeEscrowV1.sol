// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {JudgeKeyRegistry} from "./JudgeKeyRegistry.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title JudgeEscrowV1 — immutable escrow consuming finalized Misharu verdicts
/// @notice Design doc §27. The contract enforces state, deadlines, signatures,
///         replay protection, and value conservation. It never interprets
///         evidence; a verdict is an EIP-712 signature from a registry-valid
///         finalizer over exact job bindings.
///
/// Invariants enforced (§33.4):
/// - a job settles at most once; a consumed verdict nonce never settles again;
/// - amount and manifestHash are immutable after funding;
/// - only the provider submits; only registry-valid finalizers finalize;
/// - a valid challenge blocks ordinary finalization until resolved;
/// - expireAndRefund is callable by ANYONE after recoveryDeadline and is not
///   blocked by pause (§27.6);
/// - finalize/expire precedence per §27.9: before recoveryDeadline a valid
///   finalize wins; at/after it, stale finalizations revert;
/// - allocation sums to exactly 10000 bps and fee never exceeds the cap
///   committed at creation.
contract JudgeEscrowV1 {
    // ---------------------------------------------------------------- types

    enum Status {
        None,
        Open,
        Funded,
        Submitted,
        Provisional,
        Challenged,
        Completed,
        Refunded,
        Split,
        Expired,
        Cancelled
    }

    struct Job {
        address buyer;
        address provider;
        uint256 amount;
        bytes32 manifestHash;
        bytes32 deliverableHash;
        bytes32 evidenceRoot;
        Status status;
        uint64 createdAt;
        uint64 fundingNotBefore; // A1 veto delay (design §8.4); 0 = immediate
        uint64 submissionDeadline;
        uint64 challengeDeadline; // set when provisional is recorded
        uint64 recoveryDeadline;
        uint64 minChallengeWindowSeconds; // committed floor; finalizers cannot shorten
        uint16 maxFeeBps;
        uint16 provisionalProviderBps;
        uint256 challengeBond;
        address challenger;
        bytes32 provisionalVerdictHash;
        bytes32 finalVerdictHash;
    }

    struct CreateJobParams {
        address provider;
        uint256 amount;
        bytes32 manifestHash;
        uint64 fundingDelaySeconds;
        uint64 submissionDeadline;
        uint64 recoveryDeadline;
        uint64 minChallengeWindowSeconds;
        uint16 maxFeeBps;
        uint256 challengeBond;
    }

    struct FinalVerdict {
        uint256 jobId;
        bytes32 manifestHash;
        bytes32 evidenceRoot;
        bytes32 provisionalVerdictHash;
        bytes32 finalVerdictHash;
        bytes32 nonce;
        uint16 providerBps;
        uint16 buyerBps;
        uint16 feeBps;
        uint64 finalizedAt;
    }

    // ------------------------------------------------------------ constants

    string public constant PROTOCOL_NAME = "MisharuProtocol";
    string public constant PROTOCOL_VERSION = "1";

    bytes32 private constant FINAL_VERDICT_TYPEHASH = keccak256(
        "FinalVerdict(uint256 jobId,bytes32 manifestHash,bytes32 evidenceRoot,bytes32 provisionalVerdictHash,bytes32 finalVerdictHash,bytes32 nonce,uint16 providerBps,uint16 buyerBps,uint16 feeBps,uint64 finalizedAt)"
    );
    bytes32 private constant PROVISIONAL_TYPEHASH = keccak256(
        "ProvisionalRecord(uint256 jobId,bytes32 manifestHash,bytes32 evidenceRoot,bytes32 verdictHash,uint16 providerBps,uint64 challengeDeadline)"
    );
    bytes32 private constant MUTUAL_CANCEL_TYPEHASH = keccak256(
        "MutualCancel(uint256 jobId,uint16 providerBps,uint16 buyerBps,bytes32 nonce,uint64 expiresAt)"
    );

    // ------------------------------------------------------------ immutable

    IERC20 public immutable token; // allowlisted standard stablecoin (§27.7)
    JudgeKeyRegistry public immutable registry;
    address public immutable feeRecipient;
    address public immutable guardian; // can pause; can NEVER move funds
    uint256 public immutable maxJobAmount; // beta cap (decision D8)
    bytes32 public immutable domainSeparator;

    // -------------------------------------------------------------- storage

    uint256 public nextJobId = 1;
    mapping(uint256 => Job) public jobs;
    mapping(bytes32 => bool) public consumedNonces;
    bool public paused;
    uint256 private reentrancyLock = 1;

    // --------------------------------------------------------------- events

    event JobCreated(uint256 indexed jobId, address indexed buyer, address indexed provider, bytes32 manifestHash, uint256 amount);
    event JobFunded(uint256 indexed jobId);
    event Submitted(uint256 indexed jobId, bytes32 deliverableHash, bytes32 evidenceRoot);
    event ProvisionalRecorded(uint256 indexed jobId, bytes32 verdictHash, uint64 challengeDeadline);
    event Challenged(uint256 indexed jobId, address indexed challenger, bytes32 challengeHash);
    event Finalized(uint256 indexed jobId, bytes32 finalVerdictHash, uint16 providerBps, uint16 buyerBps, uint16 feeBps);
    event ExpiredAndRefunded(uint256 indexed jobId);
    event MutuallyCancelled(uint256 indexed jobId, uint16 providerBps, uint16 buyerBps);
    event PauseSet(bool paused);

    // --------------------------------------------------------------- errors

    error WrongState();
    error NotAuthorized();
    error Paused();
    error AmountMismatch();
    error AmountAboveCap();
    error DeadlineOrdering();
    error DeadlinePassed();
    error DeadlineNotReached();
    error VetoWindowOpen();
    error BindingMismatch();
    error AllocationInvalid();
    error FeeAboveCap();
    error NonceConsumed();
    error InvalidFinalizer();
    error ChallengeWindowClosed();
    error ChallengeWindowTooShort();
    error FeeOnFullRefund();
    error StaleFinalize();
    error SignatureExpired();
    error TransferFailed();
    error Reentrancy();

    // ---------------------------------------------------------- constructor

    constructor(
        IERC20 token_,
        JudgeKeyRegistry registry_,
        address feeRecipient_,
        address guardian_,
        uint256 maxJobAmount_
    ) {
        token = token_;
        registry = registry_;
        feeRecipient = feeRecipient_;
        guardian = guardian_;
        maxJobAmount = maxJobAmount_;
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(PROTOCOL_NAME)),
                keccak256(bytes(PROTOCOL_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    // ------------------------------------------------------------ modifiers

    modifier nonReentrant() {
        if (reentrancyLock != 1) revert Reentrancy();
        reentrancyLock = 2;
        _;
        reentrancyLock = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ------------------------------------------------------------ lifecycle

    function createJob(CreateJobParams calldata p) external whenNotPaused returns (uint256 jobId) {
        if (p.amount == 0 || p.amount > maxJobAmount) revert AmountAboveCap();
        if (p.submissionDeadline <= block.timestamp || p.recoveryDeadline <= p.submissionDeadline) {
            revert DeadlineOrdering();
        }
        if (p.maxFeeBps > 1000) revert FeeAboveCap(); // hard protocol ceiling: 10%
        // The committed challenge window must fit before recovery, otherwise a
        // valid provisional could never be recorded (§11.3 deadline/margin fit).
        if (p.minChallengeWindowSeconds >= p.recoveryDeadline - p.submissionDeadline) {
            revert DeadlineOrdering();
        }
        jobId = nextJobId++;
        Job storage j = jobs[jobId];
        j.buyer = msg.sender;
        j.provider = p.provider;
        j.amount = p.amount;
        j.manifestHash = p.manifestHash;
        j.status = Status.Open;
        j.createdAt = uint64(block.timestamp);
        j.fundingNotBefore = uint64(block.timestamp) + p.fundingDelaySeconds;
        j.submissionDeadline = p.submissionDeadline;
        j.recoveryDeadline = p.recoveryDeadline;
        j.minChallengeWindowSeconds = p.minChallengeWindowSeconds;
        j.maxFeeBps = p.maxFeeBps;
        j.challengeBond = p.challengeBond;
        emit JobCreated(jobId, msg.sender, p.provider, p.manifestHash, p.amount);
    }

    /// @notice Buyer funds the exact committed amount. The A1 veto window
    ///         (fundingNotBefore) gives the principal time to cancel an
    ///         agent-committed job before money locks (§8.4).
    function fund(uint256 jobId, uint256 expectedAmount) external nonReentrant whenNotPaused {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert WrongState();
        if (msg.sender != j.buyer) revert NotAuthorized();
        if (expectedAmount != j.amount) revert AmountMismatch();
        if (block.timestamp < j.fundingNotBefore) revert VetoWindowOpen();
        j.status = Status.Funded;
        _pull(msg.sender, j.amount);
        emit JobFunded(jobId);
    }

    /// @notice Buyer may cancel an unfunded job at any time (this is the veto).
    function cancelUnfunded(uint256 jobId) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Open) revert WrongState();
        if (msg.sender != j.buyer) revert NotAuthorized();
        j.status = Status.Cancelled;
        emit MutuallyCancelled(jobId, 0, 0);
    }

    function submit(uint256 jobId, bytes32 deliverableHash, bytes32 evidenceRoot) external {
        Job storage j = jobs[jobId];
        if (j.status != Status.Funded) revert WrongState();
        if (msg.sender != j.provider) revert NotAuthorized();
        if (block.timestamp > j.submissionDeadline) revert DeadlinePassed();
        j.deliverableHash = deliverableHash;
        j.evidenceRoot = evidenceRoot;
        j.status = Status.Submitted;
        emit Submitted(jobId, deliverableHash, evidenceRoot);
    }

    function recordProvisional(
        uint256 jobId,
        bytes32 verdictHash,
        uint16 providerBps,
        uint64 challengeDeadline,
        bytes calldata finalizerSignature
    ) external whenNotPaused {
        Job storage j = jobs[jobId];
        if (j.status != Status.Submitted) revert WrongState();
        if (challengeDeadline <= block.timestamp || challengeDeadline >= j.recoveryDeadline) {
            revert DeadlineOrdering();
        }
        // SECURITY: a finalizer must not be able to shrink the challenge window
        // the parties committed to. Without this, a compromised finalizer could
        // record a provisional verdict with a 1-second window and finalize
        // before either party could challenge (design §33.1 "Judge operator
        // compromise", §24 challenge rights).
        if (challengeDeadline - uint64(block.timestamp) < j.minChallengeWindowSeconds) {
            revert ChallengeWindowTooShort();
        }
        bytes32 structHash = keccak256(
            abi.encode(PROVISIONAL_TYPEHASH, jobId, j.manifestHash, j.evidenceRoot, verdictHash, providerBps, challengeDeadline)
        );
        address signer = _recover(structHash, finalizerSignature);
        if (!registry.isValidAt(signer, uint64(block.timestamp))) revert InvalidFinalizer();
        j.provisionalVerdictHash = verdictHash;
        j.provisionalProviderBps = providerBps;
        j.challengeDeadline = challengeDeadline;
        j.status = Status.Provisional;
        emit ProvisionalRecorded(jobId, verdictHash, challengeDeadline);
    }

    /// @notice Buyer or provider may challenge during the window, posting the
    ///         committed bond. Challenge is deliberately NOT pausable: it is a
    ///         protective action.
    function challenge(uint256 jobId, bytes32 challengeHash) external nonReentrant {
        Job storage j = jobs[jobId];
        if (j.status != Status.Provisional) revert WrongState();
        if (msg.sender != j.buyer && msg.sender != j.provider) revert NotAuthorized();
        if (block.timestamp >= j.challengeDeadline) revert ChallengeWindowClosed();
        j.status = Status.Challenged;
        j.challenger = msg.sender;
        if (j.challengeBond > 0) _pull(msg.sender, j.challengeBond);
        emit Challenged(jobId, msg.sender, challengeHash);
    }

    /// @notice Consume a finalized verdict. From Provisional: only after the
    ///         challenge window. From Challenged: the verdict is the signed
    ///         resolution. Bond routing follows fault attribution by outcome
    ///         change (§24.6): outcome changed → bond back to challenger;
    ///         unchanged → bond to the counterparty.
    function finalize(FinalVerdict calldata v, bytes calldata finalizerSignature)
        external
        nonReentrant
        whenNotPaused
    {
        Job storage j = jobs[v.jobId];
        bool fromChallenge = j.status == Status.Challenged;
        if (j.status != Status.Provisional && !fromChallenge) revert WrongState();
        if (!fromChallenge && block.timestamp < j.challengeDeadline) revert ChallengeWindowClosed();
        // §27.9 precedence: stale finalizations are rejected at/after recovery.
        if (block.timestamp >= j.recoveryDeadline) revert StaleFinalize();
        if (v.manifestHash != j.manifestHash || v.evidenceRoot != j.evidenceRoot) revert BindingMismatch();
        if (v.provisionalVerdictHash != j.provisionalVerdictHash) revert BindingMismatch();
        if (uint256(v.providerBps) + v.buyerBps + v.feeBps != 10_000) revert AllocationInvalid();
        if (v.feeBps > j.maxFeeBps) revert FeeAboveCap();
        // Recovery is never monetized: a full refund carries no protocol fee
        // (docs/business/fee-model.md; design §26.6).
        if (v.providerBps == 0 && v.feeBps != 0) revert FeeOnFullRefund();
        if (consumedNonces[v.nonce]) revert NonceConsumed();
        bytes32 structHash = keccak256(
            abi.encode(
                FINAL_VERDICT_TYPEHASH,
                v.jobId,
                v.manifestHash,
                v.evidenceRoot,
                v.provisionalVerdictHash,
                v.finalVerdictHash,
                v.nonce,
                v.providerBps,
                v.buyerBps,
                v.feeBps,
                v.finalizedAt
            )
        );
        address signer = _recover(structHash, finalizerSignature);
        if (!registry.isValidAt(signer, v.finalizedAt)) revert InvalidFinalizer();

        consumedNonces[v.nonce] = true;
        j.finalVerdictHash = v.finalVerdictHash;
        // Completed = provider received everything except protocol fee;
        // Refunded = buyer received everything; anything else is a split.
        j.status = v.buyerBps == 0
            ? Status.Completed
            : (v.providerBps == 0 ? Status.Refunded : Status.Split);

        uint256 amount = j.amount;
        uint256 fee = (amount * v.feeBps) / 10_000;
        uint256 toProvider = (amount * v.providerBps) / 10_000;
        uint256 toBuyer = amount - toProvider - fee; // remainder to buyer: conservation
        if (toProvider > 0) _push(j.provider, toProvider);
        if (toBuyer > 0) _push(j.buyer, toBuyer);
        if (fee > 0) _push(feeRecipient, fee);

        if (fromChallenge && j.challengeBond > 0) {
            bool outcomeChanged = v.providerBps != j.provisionalProviderBps;
            address counterparty = j.challenger == j.buyer ? j.provider : j.buyer;
            _push(outcomeChanged ? j.challenger : counterparty, j.challengeBond);
        }
        emit Finalized(v.jobId, v.finalVerdictHash, v.providerBps, v.buyerBps, v.feeBps);
    }

    /// @notice Liveness guarantee (§27.6/§27.9): after recoveryDeadline anyone
    ///         can trigger a full refund of principal (and bond, back to the
    ///         challenger). NOT gated by pause. Cannot be blocked by any hook.
    function expireAndRefund(uint256 jobId_) external nonReentrant {
        Job storage j = jobs[jobId_];
        Status s = j.status;
        bool refundable = s == Status.Funded || s == Status.Submitted || s == Status.Provisional
            || s == Status.Challenged;
        if (!refundable) revert WrongState();
        if (block.timestamp < j.recoveryDeadline) revert DeadlineNotReached();
        j.status = Status.Expired;
        _push(j.buyer, j.amount);
        if (s == Status.Challenged && j.challengeBond > 0) _push(j.challenger, j.challengeBond);
        emit ExpiredAndRefunded(jobId_);
    }

    /// @notice Both parties may settle by mutual signed agreement before a
    ///         terminal state (design §26.14). No fee on mutual cancel.
    function mutualCancel(
        uint256 jobId_,
        uint16 providerBps,
        uint16 buyerBps,
        bytes32 nonce,
        uint64 expiresAt,
        bytes calldata buyerSignature,
        bytes calldata providerSignature
    ) external nonReentrant {
        Job storage j = jobs[jobId_];
        Status s = j.status;
        bool cancellable = s == Status.Funded || s == Status.Submitted || s == Status.Provisional
            || s == Status.Challenged;
        if (!cancellable) revert WrongState();
        if (block.timestamp > expiresAt) revert SignatureExpired();
        if (uint256(providerBps) + buyerBps != 10_000) revert AllocationInvalid();
        if (consumedNonces[nonce]) revert NonceConsumed();
        bytes32 structHash =
            keccak256(abi.encode(MUTUAL_CANCEL_TYPEHASH, jobId_, providerBps, buyerBps, nonce, expiresAt));
        if (_recover(structHash, buyerSignature) != j.buyer) revert NotAuthorized();
        if (_recover(structHash, providerSignature) != j.provider) revert NotAuthorized();

        consumedNonces[nonce] = true;
        j.status = Status.Cancelled;
        uint256 toProvider = (j.amount * providerBps) / 10_000;
        uint256 toBuyer = j.amount - toProvider;
        if (toProvider > 0) _push(j.provider, toProvider);
        if (toBuyer > 0) _push(j.buyer, toBuyer);
        if (s == Status.Challenged && j.challengeBond > 0) _push(j.challenger, j.challengeBond);
        emit MutuallyCancelled(jobId_, providerBps, buyerBps);
    }

    // ----------------------------------------------------------- governance

    /// @notice Pause blocks NEW commitments and finalizations. It never blocks
    ///         expireAndRefund, challenge, or mutualCancel (§27.6).
    function setPaused(bool paused_) external {
        if (msg.sender != guardian) revert NotAuthorized();
        paused = paused_;
        emit PauseSet(paused_);
    }

    // ---------------------------------------------------------------- views

    function jobStatus(uint256 jobId_) external view returns (Status) {
        return jobs[jobId_].status;
    }

    // ------------------------------------------------------------- internal

    function _recover(bytes32 structHash, bytes calldata signature) private view returns (address) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        if (signature.length != 65) revert NotAuthorized();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 vv = uint8(signature[64]);
        // Reject malleable high-s signatures.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert NotAuthorized();
        }
        address signer = ecrecover(digest, vv, r, s);
        if (signer == address(0)) revert NotAuthorized();
        return signer;
    }

    function _pull(address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }
}
