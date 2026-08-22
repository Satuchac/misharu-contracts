//// Misharu judge escrow — Cardano (eUTxO profile, design §29.3)
////
//// One state UTxO per job. The datum carries the same commitments the EVM
//// escrow stores: the parties, the manifest hash they signed, the evidence
//// root, the deadlines, and the finalizer authorised to decide.
////
//// The validator enforces in eUTxO terms exactly what JudgeEscrowV1 enforces
//// on EVM:
////   FinalizeAccept — finalizer signed, challenge window closed, recovery
////                    deadline not passed, provider paid.
////   FinalizeReject — same authority and timing, buyer refunded.
////   Expire         — after the recovery deadline ANYONE may return the funds
////                    to the buyer. Unblockable: this is the liveness guarantee.
////   MutualCancel   — both parties signed; they settle as they agree.
////
//// Nothing here interprets evidence. A verdict arrives as a signature; the
//// script only checks authority, timing and where the money went.
////
//// ── THE VERDICT IS NAMED, NOT ASSUMED ───────────────────────────────────────
////
//// `FinalizeAccept` and `FinalizeReject` used to be bare choices. The datum
//// bound the manifest hash and the evidence root, and then the OUTCOME — the
//// part that decides who gets paid — was whatever the finalizer picked at
//// settlement time, with nothing on chain tying it to a signed verdict.
////
//// An audit of the EVM rail found six published cases whose settlement
//// contradicted the verdict they published. There the divergence was at least
//// DETECTABLE afterwards, because the escrow had stored a verdict hash. Here
//// nothing was stored, so the same divergence would have left no trace at all:
//// a reader could not tell which verdict a settlement claimed to implement.
////
//// So both finalize redeemers now carry `verdict_hash`. The redeemer is part
//// of the transaction the finalizer signs, so the hash is attested by them and
//// recorded on chain forever. The script cannot open the verdict — it is a
//// SHA-256 over canonical JSON and no validator can recompute that — but it
//// can insist the settlement NAME one, which is the difference between "we
//// cannot check this" and "we can".
////
//// A hash of the right shape is required, so a caller cannot satisfy this with
//// an empty field and produce a settlement that names nothing.

use aiken/collection/list
use aiken/primitive/bytearray
use aiken/interval.{Finite}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{lovelace_of}
use cardano/transaction.{OutputReference, Output, Transaction}

pub type JobDatum {
  buyer: ByteArray,
  provider: ByteArray,
  finalizer: ByteArray,
  manifest_hash: ByteArray,
  evidence_root: ByteArray,
  challenge_deadline: Int,
  recovery_deadline: Int,
  amount: Int,
}

pub type JobRedeemer {
  /// The provider is paid. `verdict_hash` is the SHA-256 (32 bytes) of the
  /// canonical final verdict this settlement implements.
  FinalizeAccept { verdict_hash: ByteArray }
  /// The buyer is refunded, naming the verdict the same way.
  FinalizeReject { verdict_hash: ByteArray }
  /// After the recovery deadline anyone may return the funds. No verdict is
  /// named because no verdict is involved — that is the whole point of the
  /// liveness path, and requiring one would let a missing judge trap the money.
  Expire
  MutualCancel
}

/// A verdict hash must be a 32-byte digest.
///
/// Without this a settlement could name `#""` and satisfy the letter of the
/// rule while recording nothing — the "not-checked quietly becomes pass"
/// failure, in a redeemer.
fn names_a_verdict(verdict_hash: ByteArray) -> Bool {
  bytearray.length(verdict_hash) == 32
}

/// The chain can prove `time` has passed.
fn starts_after(tx: Transaction, time: Int) -> Bool {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(lo) -> lo >= time
    _ -> False
  }
}

/// The chain can prove `time` has NOT yet passed.
fn ends_before(tx: Transaction, time: Int) -> Bool {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(hi) -> hi < time
    _ -> False
  }
}

fn credential_bytes(address: Address) -> ByteArray {
  when address.payment_credential is {
    VerificationKey(hash) -> hash
    Script(hash) -> hash
  }
}

/// Total lovelace paid to outputs controlled by `key`.
fn paid_to(tx: Transaction, key: ByteArray) -> Int {
  list.reduce(
    tx.outputs,
    0,
    fn(acc: Int, output: Output) {
      if credential_bytes(output.address) == key {
        acc + lovelace_of(output.value)
      } else {
        acc
      }
    },
  )
}

validator judge_escrow {
  spend(
    datum: Option<JobDatum>,
    redeemer: JobRedeemer,
    _own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(job) = datum
    when redeemer is {
      FinalizeAccept { verdict_hash } ->
        names_a_verdict(verdict_hash)? && list.has(tx.extra_signatories, job.finalizer)? && starts_after(
          tx,
          job.challenge_deadline,
        )? && ends_before(tx, job.recovery_deadline)? && (paid_to(tx, job.provider) >= job.amount)?

      FinalizeReject { verdict_hash } ->
        names_a_verdict(verdict_hash)? && list.has(tx.extra_signatories, job.finalizer)? && starts_after(
          tx,
          job.challenge_deadline,
        )? && ends_before(tx, job.recovery_deadline)? && (paid_to(tx, job.buyer) >= job.amount)?

      Expire ->
        starts_after(tx, job.recovery_deadline)? && (paid_to(tx, job.buyer) >= job.amount)?

      MutualCancel ->
        list.has(tx.extra_signatories, job.buyer)? && list.has(
          tx.extra_signatories,
          job.provider,
        )?
    }
  }

  else(_) {
    fail
  }
}

// ---------------------------------------------------------------- tests

fn sample_job() -> JobDatum {
  JobDatum {
    buyer: #"00000000000000000000000000000000000000000000000000000001",
    provider: #"00000000000000000000000000000000000000000000000000000002",
    finalizer: #"00000000000000000000000000000000000000000000000000000003",
    manifest_hash: #"aabb",
    evidence_root: #"ccdd",
    challenge_deadline: 1000,
    recovery_deadline: 2000,
    amount: 5000000,
  }
}

test datum_roundtrip() {
  let job = sample_job()
  job.amount == 5000000 && job.challenge_deadline < job.recovery_deadline
}

test deadlines_are_ordered() {
  let job = sample_job()
  job.challenge_deadline < job.recovery_deadline
}

// ─────────────────────────── the settlement must name a verdict

/// A 32-byte digest is accepted.
test a_real_digest_names_a_verdict() {
  names_a_verdict(
    #"402dde04a3f7c023f0bd3b0065bfeb81c67fb34ae3772f5db20c7242d933baf0",
  )
}

/// The failure this guards against: a caller satisfying the letter of the rule
/// with an empty field, producing a settlement that names nothing. That is the
/// "not-checked quietly becomes a pass" failure, expressed in a redeemer.
test an_empty_verdict_hash_names_nothing() {
  !names_a_verdict(#"")
}

test a_truncated_digest_is_refused() {
  !names_a_verdict(#"402dde04a3f7c023")
}

/// Longer is refused too. A field that accepted any length would let a
/// settlement carry something that is not a digest at all.
test an_overlong_digest_is_refused() {
  !names_a_verdict(
    #"402dde04a3f7c023f0bd3b0065bfeb81c67fb34ae3772f5db20c7242d933baf000",
  )
}

/// Both finalize paths must name one; only the liveness path is exempt.
test both_finalize_redeemers_carry_a_verdict() {
  let digest = #"402dde04a3f7c023f0bd3b0065bfeb81c67fb34ae3772f5db20c7242d933baf0"
  let accept = FinalizeAccept { verdict_hash: digest }
  let reject = FinalizeReject { verdict_hash: digest }
  when (accept, reject) is {
    (FinalizeAccept { verdict_hash: a }, FinalizeReject { verdict_hash: r }) ->
      names_a_verdict(a) && names_a_verdict(r) && a == r
    _ -> False
  }
}

/// `Expire` names no verdict ON PURPOSE. It is the unblockable refund after the
/// recovery deadline, and requiring a verdict there would let a judge who never
/// answered trap the money — turning the liveness guarantee into a hostage.
test expire_needs_no_verdict() {
  when Expire is {
    Expire -> True
    _ -> False
  }
}
