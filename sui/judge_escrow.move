/// Misharu judge escrow — Sui (Move profile, design §29.5)
///
/// A `Job` is a shared object holding the locked `Coin<SUI>` plus the same
/// commitments the EVM and Cardano implementations carry: the parties, the
/// manifest hash they signed, the evidence root, the deadlines, and the
/// finalizer authorised to decide.
///
/// The invariants mirrored from `JudgeEscrowV1`:
///  * a job settles at most once (`status` becomes terminal and never moves);
///  * only the provider may submit;
///  * only the declared finalizer may record a verdict;
///  * a verdict cannot be finalised before the committed challenge deadline;
///  * after the recovery deadline ANYONE may refund the buyer, and that path
///    can never be blocked — the liveness guarantee;
///  * value is conserved: the locked balance leaves in exactly one payout.
///
/// Nothing here interprets evidence. A verdict arrives as an authorised call
/// from the finalizer; the module only checks authority, timing and destination.
module misharu_escrow::judge_escrow;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;

// ---------------------------------------------------------------- errors

// 1 was ENotBuyer, used by the withdrawn unilateral mutual_cancel. Left
// unassigned so existing error-code tables keep their meaning.
const ENotProvider: u64 = 2;
const ENotFinalizer: u64 = 3;
const EWrongState: u64 = 4;
const EChallengeWindowOpen: u64 = 5;
const ERecoveryDeadlinePassed: u64 = 6;
const ERecoveryDeadlineNotReached: u64 = 7;
const EDeadlineOrdering: u64 = 8;
const EAmountMismatch: u64 = 9;
const EChallengeWindowTooShort: u64 = 10;
const ENotParty: u64 = 11;
const ENotCounterparty: u64 = 12;
const ENoCancelProposal: u64 = 13;
const EAllocationInvalid: u64 = 14;
const EAllocationMismatch: u64 = 15;
/// A settlement that does not name the verdict it implements.
const EVerdictNotNamed: u64 = 16;

// ---------------------------------------------------------------- status

const STATUS_FUNDED: u8 = 1;
const STATUS_SUBMITTED: u8 = 2;
const STATUS_PROVISIONAL: u8 = 3;
const STATUS_COMPLETED: u8 = 4;
const STATUS_REFUNDED: u8 = 5;
const STATUS_EXPIRED: u8 = 6;

public struct Job has key {
    id: UID,
    buyer: address,
    provider: address,
    finalizer: address,
    manifest_hash: vector<u8>,
    evidence_root: vector<u8>,
    deliverable_hash: vector<u8>,
    escrow: Balance<SUI>,
    amount: u64,
    status: u8,
    /// committed floor a finalizer cannot shorten (ms)
    min_challenge_window_ms: u64,
    submission_deadline_ms: u64,
    challenge_deadline_ms: u64,
    recovery_deadline_ms: u64,
    /// Party that proposed a cancellation, if any. A cancellation needs the
    /// agreement of BOTH parties; a Sui transaction has a single sender, so
    /// consent is expressed across two transactions instead of two signatures.
    cancel_proposer: Option<address>,
    /// Allocation the proposer offered, in basis points to the provider. The
    /// accepting party must repeat it, so both sides commit to the same terms.
    cancel_provider_bps: u64,
    /// The verdict this job settled under. Empty until it settles.
    ///
    /// It used to be absent entirely. The object bound the manifest hash and
    /// the evidence root, and then the outcome — the part deciding who is paid
    /// — was a bare boolean with nothing on chain tying it to a signed verdict.
    /// An audit of the EVM rail found six published cases whose settlement
    /// contradicted their own verdict; there it was at least DETECTABLE
    /// afterwards, because that escrow stored a verdict hash. Here nothing was
    /// stored, so the same divergence would have left no trace.
    ///
    /// Move cannot open the verdict — it is a SHA-256 over canonical JSON — but
    /// it can insist the settlement NAME one and keep it.
    settled_verdict_hash: vector<u8>,
}

public struct JobCreated has copy, drop { job: address, buyer: address, provider: address, amount: u64 }
public struct Submitted has copy, drop { job: address, evidence_root: vector<u8> }
public struct ProvisionalRecorded has copy, drop { job: address, challenge_deadline_ms: u64 }
public struct Finalized has copy, drop { job: address, to: address, amount: u64 }
public struct Expired has copy, drop { job: address, amount: u64 }
public struct CancelProposed has copy, drop { job: address, proposer: address, provider_bps: u64 }
public struct CancelAccepted has copy, drop { job: address, accepter: address, to_provider: u64, to_buyer: u64 }

/// Create and fund a job in one call: on Sui the coin is the funding.
public fun create_and_fund(
    payment: Coin<SUI>,
    provider: address,
    finalizer: address,
    manifest_hash: vector<u8>,
    min_challenge_window_ms: u64,
    submission_deadline_ms: u64,
    recovery_deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let now = clock::timestamp_ms(clock);
    assert!(submission_deadline_ms > now, EDeadlineOrdering);
    assert!(recovery_deadline_ms > submission_deadline_ms, EDeadlineOrdering);
    assert!(min_challenge_window_ms < recovery_deadline_ms - submission_deadline_ms, EDeadlineOrdering);

    let amount = coin::value(&payment);
    assert!(amount > 0, EAmountMismatch);

    let job = Job {
        id: object::new(ctx),
        buyer: ctx.sender(),
        provider,
        finalizer,
        manifest_hash,
        evidence_root: vector::empty(),
        deliverable_hash: vector::empty(),
        escrow: coin::into_balance(payment),
        amount,
        status: STATUS_FUNDED,
        min_challenge_window_ms,
        submission_deadline_ms,
        challenge_deadline_ms: 0,
        recovery_deadline_ms,
        cancel_proposer: option::none(),
        cancel_provider_bps: 0,
        // No verdict yet; finalizing names one and stores it here.
        settled_verdict_hash: vector::empty<u8>(),
    };
    event::emit(JobCreated { job: object::uid_to_address(&job.id), buyer: job.buyer, provider, amount });
    transfer::share_object(job);
}

/// Only the provider submits, and only before the submission deadline.
public fun submit(
    job: &mut Job,
    deliverable_hash: vector<u8>,
    evidence_root: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(job.status == STATUS_FUNDED, EWrongState);
    assert!(ctx.sender() == job.provider, ENotProvider);
    assert!(clock::timestamp_ms(clock) <= job.submission_deadline_ms, EDeadlineOrdering);
    job.deliverable_hash = deliverable_hash;
    job.evidence_root = evidence_root;
    job.status = STATUS_SUBMITTED;
    event::emit(Submitted { job: object::uid_to_address(&job.id), evidence_root });
}

/// The finalizer publishes a provisional verdict and opens the challenge
/// window. The committed floor is enforced here: a finalizer cannot shrink
/// the window the parties agreed to.
public fun record_provisional(
    job: &mut Job,
    challenge_deadline_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(job.status == STATUS_SUBMITTED, EWrongState);
    assert!(ctx.sender() == job.finalizer, ENotFinalizer);
    let now = clock::timestamp_ms(clock);
    assert!(challenge_deadline_ms > now, EDeadlineOrdering);
    assert!(challenge_deadline_ms < job.recovery_deadline_ms, EDeadlineOrdering);
    assert!(challenge_deadline_ms - now >= job.min_challenge_window_ms, EChallengeWindowTooShort);
    job.challenge_deadline_ms = challenge_deadline_ms;
    job.status = STATUS_PROVISIONAL;
    event::emit(ProvisionalRecorded { job: object::uid_to_address(&job.id), challenge_deadline_ms });
}

/// Consume the verdict. `pay_provider` true releases, false refunds.
/// Only after the challenge window, only before the recovery deadline.
///
/// `verdict_hash` is the 32-byte SHA-256 of the canonical final verdict this
/// settlement implements. It is recorded on the object, so a settlement can be
/// compared to the decision it claims to carry out.
public fun finalize(
    job: &mut Job,
    pay_provider: bool,
    verdict_hash: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(job.status == STATUS_PROVISIONAL, EWrongState);
    assert!(ctx.sender() == job.finalizer, ENotFinalizer);
    // A settlement must NAME the verdict it implements. Anything other than a
    // 32-byte digest names nothing, and accepting an empty vector would satisfy
    // the letter of the rule while recording no more than the old bare boolean.
    assert!(vector::length(&verdict_hash) == 32, EVerdictNotNamed);
    let now = clock::timestamp_ms(clock);
    assert!(now >= job.challenge_deadline_ms, EChallengeWindowOpen);
    assert!(now < job.recovery_deadline_ms, ERecoveryDeadlinePassed);

    let amount = balance::value(&job.escrow);
    let payout = coin::from_balance(balance::split(&mut job.escrow, amount), ctx);
    let recipient = if (pay_provider) { job.provider } else { job.buyer };
    job.settled_verdict_hash = verdict_hash;
    job.status = if (pay_provider) { STATUS_COMPLETED } else { STATUS_REFUNDED };
    transfer::public_transfer(payout, recipient);
    event::emit(Finalized { job: object::uid_to_address(&job.id), to: recipient, amount });
}

/// Liveness: after the recovery deadline ANYONE may return the funds to the
/// buyer. No authority check by design — this must never be blockable.
public fun expire_and_refund(job: &mut Job, clock: &Clock, ctx: &mut TxContext) {
    assert!(
        job.status == STATUS_FUNDED || job.status == STATUS_SUBMITTED || job.status == STATUS_PROVISIONAL,
        EWrongState,
    );
    assert!(clock::timestamp_ms(clock) >= job.recovery_deadline_ms, ERecoveryDeadlineNotReached);
    let amount = balance::value(&job.escrow);
    let payout = coin::from_balance(balance::split(&mut job.escrow, amount), ctx);
    job.status = STATUS_EXPIRED;
    transfer::public_transfer(payout, job.buyer);
    event::emit(Expired { job: object::uid_to_address(&job.id), amount });
}

/// Propose a cancellation on stated terms. Either party may propose; nothing
/// moves until the counterparty accepts the same terms.
///
/// `provider_bps` is the share of the escrow going to the provider, so a
/// straight refund is 0 and a full release is 10 000. Proposing again replaces
/// the previous offer, which is how a counter-offer is made.
public fun propose_cancel(job: &mut Job, provider_bps: u64, ctx: &TxContext) {
    assert!(is_active(job), EWrongState);
    let sender = ctx.sender();
    assert!(sender == job.buyer || sender == job.provider, ENotParty);
    assert!(provider_bps <= 10_000, EAllocationInvalid);
    job.cancel_proposer = option::some(sender);
    job.cancel_provider_bps = provider_bps;
    event::emit(CancelProposed { job: object::uid_to_address(&job.id), proposer: sender, provider_bps });
}

/// Withdraw an outstanding proposal. Only its author may retract it.
public fun withdraw_cancel_proposal(job: &mut Job, ctx: &TxContext) {
    assert!(option::is_some(&job.cancel_proposer), ENoCancelProposal);
    assert!(ctx.sender() == *option::borrow(&job.cancel_proposer), ENotCounterparty);
    job.cancel_proposer = option::none();
    job.cancel_provider_bps = 0;
}

/// Accept an outstanding proposal and settle on its terms.
///
/// This is the ONLY path that moves money by agreement rather than by verdict,
/// so it demands the consent of both sides. The caller must be the party that
/// did NOT propose, and must repeat the proposed allocation: passing different
/// terms is a counter-offer, not an acceptance, and is rejected.
public fun accept_cancel(job: &mut Job, provider_bps: u64, ctx: &mut TxContext) {
    assert!(is_active(job), EWrongState);
    assert!(option::is_some(&job.cancel_proposer), ENoCancelProposal);
    let proposer = *option::borrow(&job.cancel_proposer);
    let sender = ctx.sender();
    assert!(sender == job.buyer || sender == job.provider, ENotParty);
    // The proposer cannot accept their own proposal — that would be exactly
    // the unilateral cancellation this two-step exists to prevent.
    assert!(sender != proposer, ENotCounterparty);
    assert!(provider_bps == job.cancel_provider_bps, EAllocationMismatch);

    let total = balance::value(&job.escrow);
    let to_provider = total * provider_bps / 10_000;
    let to_buyer = total - to_provider;

    if (to_provider > 0) {
        let p = coin::from_balance(balance::split(&mut job.escrow, to_provider), ctx);
        transfer::public_transfer(p, job.provider);
    };
    if (to_buyer > 0) {
        let b = coin::from_balance(balance::split(&mut job.escrow, to_buyer), ctx);
        transfer::public_transfer(b, job.buyer);
    };

    job.status = STATUS_REFUNDED;
    job.cancel_proposer = option::none();
    event::emit(CancelAccepted {
        job: object::uid_to_address(&job.id), accepter: sender, to_provider, to_buyer,
    });
}

/// A job that has not reached a terminal state.
fun is_active(job: &Job): bool {
    job.status == STATUS_FUNDED || job.status == STATUS_SUBMITTED || job.status == STATUS_PROVISIONAL
}

// ------------------------------------------------------------------ views

public fun status(job: &Job): u8 { job.status }
public fun amount(job: &Job): u64 { job.amount }
public fun manifest_hash(job: &Job): vector<u8> { job.manifest_hash }

/// The verdict this job settled under; empty while it has not settled.
public fun settled_verdict_hash(job: &Job): vector<u8> { job.settled_verdict_hash }
public fun evidence_root(job: &Job): vector<u8> { job.evidence_root }
public fun locked(job: &Job): u64 { balance::value(&job.escrow) }
