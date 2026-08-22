# Audit: does the chain know what the verdict said?

**2026-08-22**

A Misharu case publishes a signed verdict and points at an on-chain settlement.
This audit asks one question of every rail:

> **Can the settlement contradict the verdict it claims to implement, and would
> anyone be able to tell?**

It was prompted by finding that on our largest rail the answer was *yes* and
*no* — six published cases moved money in a way their own signed verdicts
denied, and nothing in the system had noticed for months.

---

## 1. What was found

Reading the Base Sepolia escrow back and comparing it to what we had published:

| case | the committed verdict says | the chain paid |
|---|---|---|
| `base-sepolia-demo-job9-accept` | `INDETERMINATE`, allocate `{provider 0, buyer 0}` | provider **9900**, fee 100 |
| 5 × `…-challenge_split` | provider **10000**, buyer 0 | provider **5000**, buyer **4900** |

Job 9 is the serious one. `INDETERMINATE` means *the judge declined to decide*;
the manifest's own settlement policy for it is `FREEZE_UNTIL_APPEAL_OR_TIMEOUT`.
A frozen case paid out.

**Why nothing caught it.** Every check we had compared the document to itself.
The manifest hash matched, the evidence root matched, the verdict hash on chain
matched the verdict in the bundle, the signatures verified. All true, and all
beside the point: the bundle was internally consistent *and* described something
that did not happen. In `job6` the human-readable summary was **correct**
("Split, provider 50 tUSDC, buyer 49 tUSDC") while the signed, hash-committed
final verdict was the part that was wrong.

### Two root causes, both structural

1. **`finalizeVerdict()` could not express a challenge resolution.** It copied
   the provisional allocation and had no parameter for anything else. So every
   challenge-resolved case was wrong *by construction* — the type could not say
   what had happened.

2. **The settlement computed its own allocation.** `run-judgements.ts` built the
   escrow's `providerBps/buyerBps/feeBps` from `agg.outcome` and the scenario
   label, beside the verdict rather than from it, and nothing compared them. The
   comment directly above that code said:

   > *The settlement MUST follow the verdict the engine actually produced.
   > Deriving it from the scenario label would let money move against an
   > INDETERMINATE outcome — precisely what the protocol forbids.*

   The code beneath it did exactly that. A comment is not an invariant.

## 2. Every rail, same question

| rail | manifest bound | evidence bound | verdict on chain | settlement bound to it |
|---|---|---|---|---|
| **EVM (V2)** | yes | yes | hash only | **no** — six divergent cases |
| **EVM (V3)** | yes | yes | hash **+ the shares paid** | **yes**, unchallenged |
| **Cardano Preprod** (v1) | yes | yes | **nothing** | no — free `FinalizeAccept`/`FinalizeReject` |
| **Cardano Preprod** (v2) | yes | yes | the verdict hash, in the redeemer | names it |
| **Solana Devnet** (before) | yes | yes | **nothing** | no — `Finalize { pay_provider: bool }` |
| **Solana Devnet** (now) | yes | yes | `settled_verdict_hash` on the account | names it |
| **Sui Testnet** (v1) | yes | yes | **nothing** | no — `finalize(… pay_provider)` |
| **Sui Testnet** (v2) | yes | yes | `settled_verdict_hash` on the object | names it |
| **Midnight Preprod** | yes | yes | **the verdict itself**, public | yes |

Three rails record the manifest and the evidence root and then take the outcome
as a bare boolean. **Cardano, Solana and Sui are in one way worse than the EVM
bug that started this**: V2 at least stored `finalVerdictHash`, so a divergence
could be *detected* afterwards by someone who thought to look. Where no verdict
is recorded, there is nothing to compare a settlement against — not now, and not
by an auditor years later.

Their exposure is narrower — none supports a partial split, so the only
available divergence is accept-versus-refund — but "the failure mode is coarser"
is not the same as "the binding exists".

**Midnight is the only rail that had it right,** which is the second time the
rail with the least usage turned out to be the strictest. It puts the verdict on
the public ledger next to the manifest hash, so the outcome is not something the
settlement can quietly disagree with.

## 3. What was fixed

**Off chain, for every rail at once.** `chainAllocation()` derives the shares
from the signed verdict and nothing else. It refuses an allocation that does not
total 10000 bps, and refuses outright to hand an `INDETERMINATE` verdict to a
settlement call. There is now exactly one place an allocation is written down.
`finalizeVerdict()` takes a `ChallengeResolution` and records a signed
`resolution: {changed_from_provisional, reason}` — a final verdict that differs
from its provisional now has to say so.

**On chain, EVM: JudgeEscrowV3.** Two changes:

1. **An unchallenged finalization must pay what the provisional awarded.** The
   provisional allocation is already on chain; if nobody challenged, there is no
   lawful reason for the final split to differ. A challenged job is exempt,
   because changing the outcome is what a challenge is *for*.
2. **The shares paid are stored, not merely emitted.** V2 put them in an event,
   so checking a settled job later meant asking an RPC provider for a
   transaction it may no longer serve. Storage is read from state.

What V3 **cannot** do: verify that `finalVerdictHash` commits to the shares
beside it. That hash is a SHA-256 over RFC 8785 canonical JSON, which the EVM
cannot recompute. No amount of Solidity closes that, and the honest answer is
that the binding is made off chain and the contract enforces what it can see.

**Publication.** `writeCase` now refuses a verdict whose key the bundle does not
publish, whose signature does not verify against it, or that names the reserved
`.test` domain — the invariant that would have prevented 100 unverifiable cases.

## 4. Proven, not asserted

V3 is deployed and the invariant was exercised against the live contract on both
EVM rails: an ordinary accept settles and its allocation is read back **out of
storage**, and a transaction shaped exactly like job 9 — provisional awarding
nothing, finalization paying 9900 — is refused by the deployed bytecode with
`SettlementContradictsProvisional(0, 9900, 100)`. The job then still settles
honestly, because a guard that bricked the escrow would be worse than the bug.

Addresses and transaction hashes: `deployments/escrow-v3-base.json`,
`deployments/escrow-v3-eth.json`.

## 4a. The other three rails now name the verdict too

Each takes the 32-byte digest of the canonical final verdict and keeps it:

- **Cardano** — `FinalizeAccept`/`FinalizeReject` carry `verdict_hash`. The
  redeemer is part of the transaction the finalizer signs, so the hash is
  attested by them and recorded forever. A non-32-byte hash is refused, because
  an empty field would satisfy the letter of the rule while recording nothing.
  `Expire` is exempt **by design**: it is the unblockable refund after the
  recovery deadline, and requiring a verdict there would let a judge who never
  answered trap the money. New script address in
  `deployments/cardano-escrow-versions.json`.
- **Solana** — `Finalize { pay_provider, verdict_hash }`, stored on the job
  account as `settled_verdict_hash`; an all-zero hash is refused.
- **Sui** — `finalize(job, pay_provider, verdict_hash, clock, ctx)`, stored on
  the object with a public accessor; anything but 32 bytes aborts with
  `EVerdictNotNamed`.

None of them can OPEN the verdict — it is a SHA-256 over canonical JSON, which
no on-chain program recomputes — so this is the V2-EVM property, not the V3 one:
a divergence becomes **detectable by anyone reading the chain**, where before it
left no trace at all. The stronger binding, refusing an unchallenged settlement
that changes the award, needs a recorded provisional allocation, which only the
EVM escrow keeps.

Addresses and transactions: `deployments/non-evm-escrows.json`.

**One consequence worth stating plainly.** Solana was upgraded in place and its
`Job` account grew from 233 to 265 bytes. borsh rejects a short buffer, so a job
account created by the old program can no longer be read by the new one. Every
devnet job at that address is already settled, so nothing is stranded — but a
mainnet upgrade must not be done this way. There it needs a new program id or a
versioned account layout. Sui avoided the equivalent problem only because adding
a field to a `key` struct is not upgrade-compatible there, which forced a new
package and left v1 jobs settleable under v1.

## 5. The corpus re-run, and what it found

Re-running the demo corpus against the fixed settlement path and the new
contracts was the real test of all of this. It produced six new cases, cleared
the class of bug that started the audit, and surfaced three more.

**The case that used to lie now tells the truth.**
`eth-sepolia-demo-job6-challenge_split` settles Split 50/49, and its signed final
verdict says `SPLIT`, allocation `{provider 5000, buyer 4900, protocol 100}`,
with a `resolution` field recording that a challenge changed the decision and
why. Under the old code that same scenario committed "provider 10000, buyer 0"
over the identical payout. It verifies offline end to end and is signed by the
published finalizer key rather than a discarded one.

**The chain check now reads storage, not transactions.** V3 stores the shares it
paid, so `chain_allocation_matches_verdict` on a V3 case reports *"read from
storage"*. On V2 the same check had to decode the finalize transaction, which
made verifying an old case depend on an RPC provider still serving it.

### Three bugs the re-run found

1. **The runner's escrow ABI had never left V1.** Its `createJob` declared nine
   fields; V2 added the panel commitment and quorum. A nine-field call against a
   V3 escrow does not encode at all, so this failed loudly — but it means the
   runner had been pinned to the V1 demo escrow the whole time.

2. **The gas estimates were three times optimistic.** `eth-sepolia-demo` claimed
   0.004 ETH per scenario; the measured cost is about 0.0125. The preflight
   check built to prevent a half-finished run used that figure and green-lit a
   run that died on the fourth scenario — the exact failure it existed to
   prevent. An estimate nobody had measured against reality is not a check.

3. **Affordability was checked once per rail, not per scenario.** Dying between
   funding and settlement leaves a funded job unsettled on chain, with the
   buyer's money locked until the recovery deadline. It now checks before every
   scenario, carries a 50% margin over measured cost, and says what to fund.

### What did NOT finish

**Both EVM deployers ran out of testnet gas.** Base Sepolia after two scenarios,
Ethereum Sepolia after three. The three non-EVM rails have not been re-run at
all. So the corpus today is a MIXTURE: six cases from the corrected path and the
rest from the code that produced the six contradictions.

That mixture is visible rather than hidden — every case carries its own
verification record, and the six bad ones are published as `failed` with the
contradiction quoted. But nobody should read "51 verified" as "the corpus is
clean". It means 51 of 173 verify, 6 are known wrong, and 116 predate the
persistent signing key and can never be checked by signature at any point in the
future.

## 6. What is still open
- **The six bad cases stand as failures.** They are published as `failed` with
  the contradiction quoted. Rewriting a committed verdict to match the chain
  would be falsifying the record; they stay wrong until re-run.
- **The corpus re-run is unfinished, blocked on testnet funds.** Both EVM
  deployers are empty; the three non-EVM rails are untouched. Funding
  `0x252298725bdec8AaBB1504f8aC239b0CbC2745C4` on Base Sepolia and Ethereum
  Sepolia, plus the Cardano/Solana/Sui party wallets, is what unblocks it.
- **116 cases can never verify by signature.** Their key was generated inside
  the settlement process and discarded. Chain verification speaks for the ones
  that settled on an EVM rail; extending it to Cardano, Solana and Sui is now
  worth doing, because those rails finally record a verdict.
