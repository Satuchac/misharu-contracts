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

use aiken/collection/list
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
  FinalizeAccept
  FinalizeReject
  Expire
  MutualCancel
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
      FinalizeAccept ->
        list.has(tx.extra_signatories, job.finalizer)? && starts_after(
          tx,
          job.challenge_deadline,
        )? && ends_before(tx, job.recovery_deadline)? && (paid_to(tx, job.provider) >= job.amount)?

      FinalizeReject ->
        list.has(tx.extra_signatories, job.finalizer)? && starts_after(
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
