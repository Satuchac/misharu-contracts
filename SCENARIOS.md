# What Misharu supports, and what each combination costs

**2026-08-20**

Every row below is exercised by `scripts/scenarios.ts` against a running
console, or by a named test. This document is the map; those are what keep it
honest. A combination that stops working fails there rather than surviving here
as a claim.

> **This is the contracts repository.** The table below describes the whole
> system, including parts that are not published here: the console, the judge
> and the scenario harness live in the engine repository, which is private.
>
> What IS here, and what a reader can therefore check without us: the
> contracts on every rail, the Noir circuits and their vector corpora, the
> deployed addresses — and `tools/`, which holds the receipt verifier, the
> panel rules and the committed-amount helper. Filenames below without a
> matching file in this repository are engine-side; they are named so the
> claim can be traced, not so you can open them here.

Testnets only. Nothing here has moved money that anyone would miss.

---

## 1. The five independent choices

An agreement is assembled from five decisions that do not constrain each other.
Any combination in this table is expressible.

| | options |
|---|---|
| **Who decides** | one AI judge · a panel of 2–9 seats, quorum M · seats are people, AI agents, or both |
| **Who sees the work** | public · sealed to the panel · shielded from the chain |
| **Who sees the price** | published · committed (a digest, plus an optional cap) |
| **Where it settles** | Base Sepolia · Cardano Preprod · Solana Devnet · Sui Testnet · Midnight Preprod · or cross-chain: judged on one, settled on another |
| **What decides a claim** | a judge's reading · a deterministic rule · **a signed oracle observation** — and a single agreement can mix all three |

---

## 2. The scenarios, and what each one hides

`+` = hidden from that party. `—` = visible to them.

| # | Scenario | Decider | Work hidden from public | Work hidden from platform | Price hidden from panel | Enforced on chain | Runs |
|---|---|---|---|---|---|---|---|
| **S1** | Ordinary escrow | 1 AI judge | — | — | — | single signature | `scenarios.ts` |
| **S2** | Two people and one AI agent | panel 2-of-3 | — | — | — | ZK rail only | `scenarios.ts` |
| **S3** | Committee sign-off | panel 4-of-6, human | — | — | — | ZK rail only | `scenarios.ts` |
| **S4** | Grant milestone review | panel 5-of-9, mixed | — | — | — | ZK rail only | `scenarios.ts` |
| **S5** | Deadlocked panel | panel 2-of-3 | — | — | — | nothing settles | `scenarios.ts` |
| **S6** | Confidential audit | panel 2-of-3 | **+** | **+** | — | ZK rail only | `scenarios.ts` |
| **S7** | Confidential fee | panel 2-of-3 | — | — | **+** | ZK rail only | `scenarios.ts` |
| **S8** | Both hidden at once | panel 2-of-3 | **+** | **+** | **+** | ZK rail only | `scenarios.ts` |
| **S9** | Refusals at setup | — | — | — | — | — | `scenarios.ts` |
| **S10** | Shielded ZK judgement | 1 AI judge | **+** | — | **+** (from the chain) | Midnight | `zk-suite.mjs` |
| **S11** | Private predicate | 1 AI judge | **+** | — | **+** | Base Sepolia verifier | `deploy-predicate-verifier.ts` |
| **S12** | Membership without disclosure | — | **+** | — | n/a | Base Sepolia verifier | `deploy-merkle-verifier.ts` |
| **S13** | Cross-chain settlement | 1 AI judge | **+** on Midnight | — | **+** on Midnight | detectable, not prevented | `cross-chain-*.ts` |
| **S14** | Parametric price bet | Pyth observation | — | — | — | Solana / Cardano | `run-market-judgements.ts` |
| **S14b** | The same, verified by a contract | Pyth, `ON_CHAIN_VERIFIED` | — | — | — | Base Sepolia verifier | `oracle-on-chain-check.ts` |
| **S14c** | **Two independent oracles must agree** | Pyth **+** Chainlink, m-of-n | — | — | — | Base Sepolia aggregator | `deploy-multi-oracle.ts` |
| **S14d** | They disagree → nobody is paid | m-of-n, quorum not met | — | — | — | refuses on chain | `MultiOracleAggregator.t.sol` |
| **S14e** | One provider dead, the rest settle | 2-of-3, one stale | — | — | — | Base Sepolia aggregator | live: API3 excluded |
| **S14f** | A first-party API provider votes | signed feed, m-of-n reporters | — | — | — | Base Sepolia, live | `deploy-signed-feed.ts` |
| **S14g** | Every oracle claim re-derived on chain | — | — | — | — | Base Sepolia | `oracle-scenarios.ts` |
| **S15** | Oracle as one claim among several | rules + judge + oracle | — | — | — | any rail | `cardano-judgement.ts` |
| **S16** | Oracle unusable → nobody is paid | Pyth observation | — | — | — | any rail | `oracle-pyth` tests |
| **S17** | Event-market settlement | Kalshi via Pyth | — | — | — | any rail | `run-market-judgements.ts` |

**"Hidden from platform" means the console and the chain, never the judges.**
Whoever decides has to read the work. That is the row where a panel changes
nothing and an AI seat actively costs you — see §5.

---

## 3. Who can be a judge

| kind | identified by | signs with | can it be enforced on chain? |
|---|---|---|---|
| **Hosted AI judge** | a registered id **and a pinned configuration version** | Ed25519 attestation key | yes, as a panel seat with a Midnight key |
| **Human signer** | a wallet address on any of the five rails | that wallet, over the vote digest | yes, as above |
| **Human signer (key)** | a registered Ed25519 key | that key, over the vote payload | yes, as above |
| **A panel of the above** | the whole set, committed in the manifest hash | each seat separately | yes, on the ZK rail: `judge_multisig` |

Pinning the version matters as much as the id. Naming a model without its
configuration is agreeing to instructions that can be rewritten after you have
signed, so an agent seat that does not pin one is refused.

An agent seat whose backend does not resolve is also refused — a seat that can
never vote quietly turns a 2-of-3 into unanimous-or-nothing.

---

## 4. Quorums

**There are two different quorums in this system and they are not related.**

| quorum | who sets it | ours to choose? |
|---|---|---|
| **Panel quorum** — how many signers must agree to release or refund | the agreement | **yes**: 2-of-3, 4-of-6, 5-of-9 |
| **Wormhole guardian quorum** — 13 of 19 | the Wormhole federation | **no** |

The second is `floor(2n/3)+1` over Wormhole's guardian set, which has nineteen
members. It is not a dial. Accepting fewer would mean accepting an attestation
Wormhole itself considers invalid, and five colluding guardians could then sign
any price they liked — which would make the on-chain verification worth nothing.
The verifier computes it from the set size rather than storing it, so it cannot
drift from the set it describes.

Everything below is about the **panel** quorum, which is ours.

The quorum must be a **majority**. At 2-of-4, two signers vote to release while
two vote to refund and *both* thresholds are met at once; which one happened
would depend on the order the votes arrived. Two disjoint majorities cannot
exist, so a majority quorum makes that impossible.

| shape | allowed | why |
|---|---|---|
| 2-of-3, 2-of-2 | yes | majority |
| 3-of-4, 3-of-5 | yes | majority |
| **4-of-6** | yes | majority |
| **5-of-9** | yes | majority |
| 2-of-4, 2-of-5, 3-of-6, 3-of-7 | **refused** | both sides could reach it |
| anything over 9 seats | **refused** | `judge_multisig` declares nine slots; a larger panel is one the ZK rail could never settle |

The console's dropdown offers only majorities, and a test asserts the page and
the server agree in both directions — so it can neither offer something that
would be refused nor hide something that would be allowed.

---

## 5. What "private" means in each layer, precisely

These get conflated constantly, and they solve different problems.

| mechanism | hides what | from whom | does NOT hide from |
|---|---|---|---|
| **Shielded ZK ledger** (Midnight) | amounts, measurements, which item was disclosed | everyone reading the chain | the judge, the platform |
| **Sealing** (X25519 + AES-GCM) | the deliverable itself | everyone except the named seats | **the seats themselves** |
| **Committed amount** | the price | everyone except the two parties | — |
| **ZK predicate** | a measurement, proving only a boolean about it | everyone | the prover |
| **Merkle membership proof** | which item, and its position | everyone | the prover |
| **Oracle observation** | *nothing* — it is evidence, and it is public by design | — | everyone |

### The one that matters most

**Every panel seat sees the work.** Sealing decides *who the audience is*, not
whether there is one — they have to read it to decide. A panel of two people and
one model means the work is visible to two people **and to whoever operates that
model**.

A panel does not fix the operator-sees-everything gap. It multiplies it by the
number of agent seats. Closing that needs a TEE, which is not built —
*TEE.md* (engine repository).

**The committed amount is the exception**: the panel decides without ever
learning the price, because the price is not evidence of whether the work was
delivered.

---

## 5a. Oracles: when a fact decides, not a judge

Some claims do not need interpreting. *"ADA/USD was above 0.20 at settlement"* is
either true or it is not, and asking a model about it would be strictly worse
than looking. So an agreement can name a **Pyth** feed and let a signed
observation decide that claim, while a judge or a panel decides the ones that
genuinely need reading.

**The oracle path never touches an LLM.** `checkObservation` is a deterministic
admission check, and the comment in the source says so in those words. A model
that could overrule a price feed would be a model that could be argued into a
payout.

### What is available

| feed | what it is |
|---|---|
| `ADA/USD`, `ETH/USD` | crypto prices |
| `XAU/USD` | gold, per troy ounce — a commodity, not a token |
| `UKOIL_SPOT` | Brent crude spot |
| Kalshi event markets | a settled event outcome, **1 or 0** — not a price |

### Two levels of trust, and the difference is not cosmetic

| level | what it means | who you are trusting |
|---|---|---|
| `ADAPTER_TLS_ONLY` | we fetched it over HTTPS and signed what we saw | us, and Pyth's TLS |
| `ADAPTER_SIGNATURE_VERIFIED` | **our adapter** parsed the Wormhole VAA and recovered guardian signatures — 13 of 19, against the pinned set and the PythNet emitter | us, to have checked honestly |
| `ON_CHAIN_VERIFIED` | **a deployed contract** recovered them, and you can repeat the call yourself | the guardians and Pyth — not us |

The third is new, and it is the one that removes us. `ADAPTER_SIGNATURE_VERIFIED`
is a real check and still a claim *about us*: a reader who does not trust this
project has to take the label on faith.

**`WormholeVaaVerifier` is live on Base Sepolia at
[`0x7a3afd62416b127026cf888ecd3ba1e97e76a3cd`](https://sepolia.basescan.org/address/0x7a3afd62416b127026cf888ecd3ba1e97e76a3cd).**
It recovers each guardian signature with `ecrecover` over
`keccak256(keccak256(body))`, requires floor(2n/3)+1 of them, requires strictly
increasing guardian indices — which makes a repeated signature unrepresentable
rather than merely detected — and requires the PythNet emitter, because
guardians sign attestations from every chain Wormhole carries.

```
cast call 0x7a3afd62416b127026cf888ecd3ba1e97e76a3cd \
  "verify(bytes)" 0x<vaa-hex> --rpc-url https://sepolia.base.org
```

Nothing of ours is involved in that command. A live ADA/USD attestation verifies
at ~165k gas; the same attestation with one byte of the body changed reverts,
because the digest moves and the recovered addresses stop being guardians.

Every case bundle records which level each observation reached, how many
signatures were recovered, and the Merkle root — so a reader can tell a price
the chain confirmed from one we merely relayed.

### The chain reads the number too, not just the signatures

Verifying the VAA left something behind that is easy to miss: the *price* was
still a number our adapter pulled out of the payload and told you about. A
dishonest adapter could take a genuine, fully verified attestation and report a
different price, and every signature check would pass.

**`PythPriceReader` is live at
[`0x309ae7a1ac0090e1d0d21c776b7956f3c0c63fb6`](https://sepolia.basescan.org/address/0x309ae7a1ac0090e1d0d21c776b7956f3c0c63fb6).**
It verifies the attestation, then proves the price message is inside the
keccak160 Merkle root the guardians signed, then parses the number out. A live
ADA/USD read returned `0.21385063` and agreed with our adapter on the price, the
publish time and the root. The same genuine attestation paired with a price that
was never in it is **refused** — with every guardian signature still valid.

**The freshness and confidence policy moved on chain with it.** Staleness and
Pyth's own confidence width used to be checked by `checkObservation` in our
adapter — which is to say, by the party who benefits from being trusted. Both
are enforced by the contract now, so a settlement cannot use a stale or
wide-confidence price even if our adapter would have allowed it. A read with a
one-second age bound reverts against the same attestation that passes at an hour.

Two smaller things it refuses that are worth naming: a **non-positive price**,
which Pyth can publish during an outage and which would make every
"≥ threshold" comparison below it trivially false; and a price dated **after the
block**, because treating a clock disagreement as freshness would make a
future-dated attestation the freshest thing available, forever.

### The upgrade is never silent, in either direction

If the chain **cannot be reached**, the observation keeps the level it had and
records that the stronger check was attempted and did not complete. An
unreachable node is not evidence that a price is wrong, and a network failure
must not quietly become a weaker claim wearing a stronger label.

If the chain **refuses**, that is a different event entirely: our adapter and a
public contract disagree about the same bytes, and one of them is wrong. The
observation is not downgraded — it fails. Publishing a number two verifiers
cannot agree about would be worse than publishing nothing.

### m-of-n oracles: two providers must agree, or nobody is paid

Verifying Pyth's signature proved *Pyth said it*. It could never prove Pyth was
**right** — a bad publisher aggregate, a compromised feed, an outage pinning a
stale value, and a Pyth-wide fault was a Misharu-wide fault. No amount of
signature checking fixes that; only a second, unrelated provider does.

**`MultiOracleAggregator` is live at
[`0x3bd99d440e3678f1e9b004473359bb6bcbfbf53b`](https://sepolia.basescan.org/address/0x3bd99d440e3678f1e9b004473359bb6bcbfbf53b)**,
over three sources from three different lineages. The count is not the point —
three sources that share plumbing are one source wearing three labels. What
matters is that their failure modes differ:

| source | lineage | how it is checked |
|---|---|---|
| **Pyth** | publishers aggregated on its own chain, attested over Wormhole | guardian signatures, then Merkle inclusion in the signed root, then the price parsed out — all on chain |
| **Chainlink** | a decentralised node network reporting to an on-chain aggregator | refuses an incomplete round, an answer carried over from an earlier round, and a non-positive answer |
| **API3** | first-party: the data providers sign their own data, no third-party node layer | refuses a missing timestamp and a non-positive value |

A live ETH/USD read:

```
pyth       $2394.70
chainlink  $2396.00
api3              —   too old
agreed     2 of 3 · spread 5 bps
PRICE      $2395.35   (median of the agreeing set)
```

### The third source is dead, and that is the useful part

The API3 dAPI on Base Sepolia **stopped updating 56 days ago** and reports
$1,574 — about a third below the market. Testnet feeds lose their sponsorship
and quietly stall.

It is excluded as too old and **named in the reading**, and the other two
settle. That is a better demonstration than three healthy feeds would have been:
the exact failure the freshness check exists for, happening for real rather than
in a fixture. A system that had silently averaged it in would have settled ETH
at about $2,120.

**Agreement is a band, not equality.** Two honest oracles never report the same
integer — they sample different venues at different instants — so sources within
`toleranceBps` of each other form a cluster, the largest cluster wins, and the
answer is the **median of that cluster** so an outlier cannot drag it. The band
is committed in the agreement; one chosen after the prices are known is a band
chosen by whoever is losing.

**It fails closed.** A median-of-three always returns something, even when all
three disagree wildly — it silently picks the middle of a mess. This refuses:
the claim goes INDETERMINATE and INDETERMINATE pays nobody, which is exactly the
rule a deadlocked panel follows. Oracles disagreeing is the situation where
guessing is worst. Asked to settle with a 0 bps band, the live contract reverts.

**One provider down is survivable** — that is what more than one is for. A source
that reverts, is stale, is dated after the block, or reports a non-positive
price is excluded and *named* in the result, never silently dropped.

The failure that would otherwise be quiet and catastrophic: two broken sources
both returning zero agree with each other perfectly, form a majority, and settle
a price of nothing. Non-positive readings are excluded before clustering, and a
test asserts zeros do not agree with each other.

### Bringing in an API provider, without trusting a relayer

A contract cannot make an HTTP request, so every "API oracle" is really somebody
putting the answer on chain. The only question is who you must trust to have
done it faithfully — and if a relayer submits a number the contract believes,
**the relayer is the oracle and the API is decoration**.

`SignedFeedSource` is the answer, and it is **live at
[`0x0558be40a3f8fcb5455c7f39551f50a739335cd0`](https://sepolia.basescan.org/address/0x0558be40a3f8fcb5455c7f39551f50a739335cd0)**:
the provider signs `(chainId, contract, feedId, price, publishTime)`, the chain
verifies against a pinned key set, and the relayer becomes a courier who cannot
alter what they carry. Every field in that digest stops a replay — across
chains, across deployments, across feeds, and across time.

Exercised against the live contract with real exchange data — Kraken $2399.73
and Coinbase $2399.88, reported as their median. All three forgeries refused on
chain: the relayer altering the price, the relayer restamping the time, and one
signature where two are required.

**Its trust level is not the same as the other three, and that is why it is not
in the production aggregator.** Pyth, Chainlink and API3 are networks whose own
operators sign. In this deployment the reporter keys are *ours*, so the chain
confirms that Misharu signed a number — not that Kraken said it. The **data** is
genuinely independent of the oracle networks; the **attestation** is only as
good as this project. Put it beside three networks and four sources would look
like four independent opinions when one of them is us.

For a real deployment the reporter keys belong to the provider, and then the
chain is confirming something nobody here can forge. That is the integration
path, and it needs the provider's signing setup rather than more code.

It requires **m of n reporters within the single provider**, so one compromised
key is not enough. That is deliberately separate from the aggregator's own
m-of-n: this asks "how sure are we that *this provider* said it", the other asks
"how many *providers* agree".

**The thing that must not be forgotten**: a provider whose data is derived from
Pyth or Chainlink is not an independent source however impeccably it signs. It
adds a signature and no information, while looking on chain exactly like genuine
diversity.

**Honest limits.** This does not fix **correlated failure**. The aggregator
counts providers, not independence: if every source ultimately reads the same
handful of exchanges, three agreeing is three views of one fact, and no contract
can tell that from real diversity. Choosing sources that do not share plumbing
is a judgement made when the agreement is written, and nothing here can make it
for you.

### An agreement can require the chain, not just benefit from it

A contract nobody can demand is a contract nobody has. `ObservationPolicy` now
carries `requireOnChainVerification`, and with it set an observation our adapter
verified but no chain did is **not admitted** — the claim goes INDETERMINATE and
INDETERMINATE pays nobody.

It is off by default on purpose: turning it on retroactively would fail every
historical case, and a party who does not need it should not pay for a chain
read on every settlement. Requiring it does not excuse anything else — a
chain-verified price that is stale, or wider than the agreement allows, or from
a feed the agreement never committed to, is still refused.

### What makes an observation refused

An observation that is not admitted does **not** fall back to a judge's opinion.
The claim goes INDETERMINATE, and an INDETERMINATE claim pays nobody.

| refusal | why it exists |
|---|---|
| `STALE` | older than the agreement's `maximumAgeSeconds` |
| `WIDE_CONFIDENCE` | Pyth's own confidence interval is wider than the agreement allows — a price nobody is sure of should not move money |
| `FEED_NOT_ALLOWED` | not one of the feeds the agreement committed to, so a relayer cannot substitute a friendlier market |
| `NOT_VERIFIED_ON_CHAIN` | the agreement demanded a chain-confirmed price and got one only our adapter had checked |

The allowed feeds are part of the manifest hash, like everything else. Otherwise
whoever fetches the data chooses which market answers the question.

### The event-market caveat, stated because it is embarrassing

A Kalshi market that has **already resolved** stops updating, and its last
publish time recedes forever — so the ordinary freshness policy rejects it as
stale. That is correct for a price and wrong for a settled fact, which is why
event markets are separated in the code rather than sitting beside ADA/USD as
though they behaved alike.

More importantly: **an already-resolved event cannot be bet on.** The property
that makes a parametric agreement meaningful is committing before the outcome
exists. Settling one of these demonstrates the plumbing, not foresight, and any
case recorded from it says so in its own bundle.

### The honest ceiling

An oracle binds a number to a *market*, not to *reality*. Pyth reporting a price
is Pyth's aggregate of its publishers; a guardian-verified VAA proves the
network said it, not that it was right. And a claim like *"the migration was
done carefully"* has no feed and never will — which is the whole reason a judge
or a panel exists alongside this.

---

## 6. Cross-chain

A case judged privately on Midnight can settle publicly on another rail.

| judged on | settles on | binding | honest label |
|---|---|---|---|
| Midnight | Base Sepolia | manifest hash **and** evidence root must match | trust-minimised, **not** trustless |
| Midnight | Cardano Preprod | as above, in the datum | as above |
| Midnight | Solana Devnet | as above | as above |

The settlement chain cannot read Midnight, so a dishonest finalizer can relay
the opposite verdict. **Nothing prevents this.** What makes it survivable is
that the Midnight verdict is public: the lie is visible to anyone who compares.
Every cross-chain receipt says so in those words.

Checking only the manifest would let a settlement pay out against work that was
never judged — same terms, different evidence is a different judgement — so both
must match.

---

## 7. Example judgements

Real bundles, verifiable offline with `pnpm verify`:

| case | what it shows |
|---|---|
| `agreement-4965d44b-accept.json` | An ordinary agreement funded and settled on Base Sepolia |
| `cardano-preprod-settled-accept-*.json` | A full judgement through the Aiken validator, datum bound to the bundle |
| `midnight-nda-bound-deliverable-321b0f.json` | Selective disclosure: two of four items shown, two withheld |
| `midnight-confidential-invoice-*.json` | A shielded invoice; the amount never reaches the ledger |
| `eth-sepolia-demo-job11-accept.json` | The demo path, end to end |
| `solana-devnet-oracle_price_bet-*.json` | A parametric bet settled from a guardian-verified Pyth observation, with the full oracle trail |
| `cardano-preprod-settled-*.json` | Rules, a judge panel and an oracle in one agreement |

167 bundles in `deployments/cases/`. **44 verify offline end to end; 123 cannot
be verified at all and say why in their own bundle** — most predate persistent
finalizer keys. That split is published at `/api/cases/verification` and is
produced by running the verifier, not asserted by hand.

---

## 8. What is not built

Stated because a capability table that lists only capabilities is marketing.

- **On-chain quorum on four of the five rails.** Base, Cardano, Solana and Sui
  check one signature each. A panel settlement there is verifiable but relayed
  by a single finalizer: detectable, not prevented. Only Midnight enforces m-of-n.
- **A TEE.** The judge — human or model — reads the evidence. Nothing stops the
  operator of an agent seat from reading it too.
- **Asymmetric quorums.** "Two of five releases, but four of five refunds" is a
  coherent thing to want and is not supported; the majority rule is symmetric.
- **Panels over nine seats.** Nine `if` branches is where this construction
  stops being reasonable; a twenty-seat panel wants different machinery.
- **A third live provider.** m-of-n is built and tested at 2-of-3; two
  independent providers are wired on Base Sepolia, so what runs is 2-of-2.
- **Anything about correlated sources.** The aggregator counts providers, not
  independence. Two oracles reading the same exchanges will agree with each
  other perfectly while both being wrong.
- **Guardian-set rotation without a redeploy.** The set index is pinned in the
  verifier's constructor. That is deliberate — a contract that accepted whatever
  index a VAA declared would accept a set nobody told it about — but it means a
  rotation needs a new deployment, on purpose rather than by oversight.
- **Price extraction on chain.** The verifier stops at the VAA: it answers "did
  enough guardians sign these bytes". Pulling an individual price out means
  walking Pyth's Merkle profile in Solidity, which is left to the caller.
- **An audit.** *THREAT-MODEL.md* (engine repository) is written by the implementer
  and has the blind spot that implies.

---

## 8a. Re-deriving the oracle claims

The deployment records assert things. `scripts/oracle-scenarios.ts` re-derives
them against the live contracts in one command: it fetches a fresh attestation,
puts it to the deployed verifier, reads the price out of the signed root,
cross-checks three providers, and tries each forgery the contracts are supposed
to refuse.

```
O1  the chain recovers the guardian signatures     quorum 13 of 19
O2  the chain reads the price from the signed root $2399.59
O3  three providers, and the quorum that decides   2 of 3, api3 too old
O4  a first-party signed feed                      3 reporters pinned
```

Adversarial by construction: a verifier that accepted everything would pass
every positive check, so the refusals are what carry the information — a
tampered body, a price not in the signed root with the signatures still valid, a
stale price, a feed the caller did not ask for, a disagreement asked to settle,
unanimity demanded while a source is dead, an unsigned price, and a signature
from nobody.

---

## 9. Running the table

```
PORT=8791 STATE_DIRECTORY=/tmp/misharu-scen node console/server.mjs &
npx tsx scripts/scenarios.ts          # S1–S9, adversarial where privacy is claimed

node contracts/midnight/deploy/multisig-sim.mjs   # 19 — quorums in the circuit
npx vitest run console/amount-blind.test.ts       # 21 — the price stays hidden
npx vitest run packages/receipt/src/sealing.test.ts  # 17 — only the panel reads it
npx tsx scripts/panel-flow.ts                     # the whole panel path over HTTP
npx tsx scripts/oracle-scenarios.ts               # every oracle claim, against the live contracts
```

`scenarios.ts` backs off when the console rate-limits it and uses a distinct
buyer per scenario. Both of those were failures first: the console defending
itself correctly against a harness that hammered it from one address. The limits
stayed; the harness changed.
