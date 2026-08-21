# Misharu contracts

**Version 0.4.0** · release digest `sha256:09828e22f925fb4d970f0d0de8e5d4272e1b91d38d8227f95b6752e8ad4a5e31`

The deployed escrow contracts behind [Misharu](https://misharu.176-102-64-240.sslip.io),
their compiled artifacts, the addresses they run at, and the evidence that the
deployed bytecode matches this source.

The adjudication engine is not in this repository. These are the contracts, so
that anyone settling through them — or reviewing a claim that they exist — can
read exactly what is running.

## What is deployed

Every rail, with how each one can be checked. They are not checked the same way,
and the differences matter more than the addresses do.

| Rail | Contract | Address | Status | How it is checked |
|---|---|---|---|---|
| Base Sepolia | Judge escrow | `0xcD0b89BBB07B614E45c78B3C55d24e48E7F6EC81` | deployed | [exact_match](https://sourcify.dev/#/lookup/0xcD0b89BBB07B614E45c78B3C55d24e48E7F6EC81) |
| Base Sepolia | Judge key registry | `0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17` | deployed | [exact_match](https://sourcify.dev/#/lookup/0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17) |
| Base Sepolia | Judge funding vault | `0xae8D16Dc169F9512233AA53BFe9BaB91485A55b7` | deployed | [exact_match](https://sourcify.dev/#/lookup/0xae8D16Dc169F9512233AA53BFe9BaB91485A55b7) |
| Base Sepolia | Demo escrow | `0x386E4A8caccad480FEa8D4611F9b365879cba218` | deployed | [exact_match](https://sourcify.dev/#/lookup/0x386E4A8caccad480FEa8D4611F9b365879cba218) |
| Ethereum Sepolia | Judge escrow | `0x89c5EA82daD056Edf7c95DBC52a1A5Be3b10D0D9` | deployed | [exact_match](https://sourcify.dev/#/lookup/0x89c5EA82daD056Edf7c95DBC52a1A5Be3b10D0D9) |
| Ethereum Sepolia | Judge key registry | `0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17` | deployed | [exact_match](https://sourcify.dev/#/lookup/0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17) |
| Ethereum Sepolia | Demo escrow | `0x9e1F8018587b96e9637dF7159Aed26eB855C7c35` | deployed | [exact_match](https://sourcify.dev/#/lookup/0x9e1F8018587b96e9637dF7159Aed26eB855C7c35) |
| Cardano Preprod | Judge escrow (Aiken, Plutus V3) | `addr_test1wqd64yljcz2qay89xucwgnh5pmjpw04e3qa44qtjra8hwqgtv5j4z` | deployed | [script hash reproduces](https://preprod.cardanoscan.io/address/addr_test1wqd64yljcz2qay89xucwgnh5pmjpw04e3qa44qtjra8hwqgtv5j4z) |
| Solana Devnet | Judge escrow (native Rust) | `954m2xXzhNpGCMrPL2chQGk8PjaAJ7i9i9B1F5JSsUZ5` | deployed | [source published](https://explorer.solana.com/address/954m2xXzhNpGCMrPL2chQGk8PjaAJ7i9i9B1F5JSsUZ5?cluster=devnet) |
| Sui Testnet | Judge escrow (Move, judge_escrow) | `0xd17f278f4d62005cc726633eea98ab9ee77f21dc96ebee0c1479d95aac246089` | deployed | [source published](https://suiscan.xyz/testnet/object/0xd17f278f4d62005cc726633eea98ab9ee77f21dc96ebee0c1479d95aac246089) |
| Midnight Preprod | Judge escrow (Compact, ZK) | — | compiled | — |
| Midnight Preprod | Judge predicates (ZK) | `ded9816a1c924e2676a59904a8faac609d9f74d7dc4f1da2a117ffb53c0c354b` | deployed | [read the ledger](https://indexer.preprod.midnight.network) |
| Midnight Preprod | Judge registry (many agreements) | `6d0647c018577f7d701ecbbb736b9918be0a0039cd54256333679c2894022c54` | deployed | [read the ledger](https://indexer.preprod.midnight.network) |
| Midnight Preprod | Judge multisig (m-of-n on chain) | `bfa7b78521cefa37c1ebdc811a316487854481693ab81507f1efb8eba9c57c1f` | deployed | [read the ledger](https://indexer.preprod.midnight.network) |
| Base Sepolia | Wormhole VAA verifier (Pyth attestations) | `0x7a3afd62416b127026cf888ecd3ba1e97e76a3cd` | deployed | [on chain](https://sepolia.basescan.org/address/0x7a3afd62416b127026cf888ecd3ba1e97e76a3cd) |
| Base Sepolia | ZK predicate verifier (UltraHonk) | `0x6ea82f8624c448a84a6c91b825d01ac687424749` | deployed | [on chain](https://sepolia.basescan.org/address/0x6ea82f8624c448a84a6c91b825d01ac687424749) |
| Base Sepolia | ZK membership verifier (UltraHonk) | `0x0f127e9fc9cda6608d14085cb4f4f7f94cc290e2` | deployed | [on chain](https://sepolia.basescan.org/address/0x0f127e9fc9cda6608d14085cb4f4f7f94cc290e2) |

**The Cardano validator carries the strongest claim here.** blake2b-224 over the
compiled script in [`cardano/plutus.json`](cardano/plutus.json) reproduces the
on-chain script hash — so it can be checked without Sourcify, without us, and
without any service being online. The EVM contracts rely on Sourcify having
recompiled and compared; Solana and Sui rely on you building the published
source yourself.

**Midnight is deployed, and its m-of-n is real.** `judge_multisig` requires m
distinct registered finalizers to approve, each in their OWN transaction from
their own machine — a circuit has one caller, so m-of-n has to mean m calls.
One caller submitting m signatures would put every key on one machine, which is
the situation it exists to end. A 2-of-3 panel of two people and one AI agent
settled through it; `deployments/panel-multisig.json` has every transaction.

**The other four rails still check one signature each.** A panel settlement on
Base, Cardano, Solana or Sui is recorded verifiably and relayed by a single
finalizer: detectable, not prevented. That gap is real and is stated here rather
than left for you to find.

**The two UltraHonk verifiers are unaudited in a specific way.** Both required
annotating their five generated assembly blocks as `memory-safe` to compile.
That annotation is an assertion to the compiler, and if it is wrong the
optimiser may produce a verifier that accepts proofs it should reject. The
blocks were read and the reasoning is in the source; it is not an audit.

## Checking a receipt, or a panel tally, without us

`tools/` is here because two of this project's louder claims are only worth
something if the code behind them is readable.

- **`verify.js`** checks a receipt offline — no install, no network, node or a
  browser. It reports INCOMPLETE where a check could not run, because a check
  that did not happen is never a pass.
- **`panel.mjs`** is the panel rule set: what makes a quorum valid, and how
  votes are counted. "Anyone can recompute the tally from the published votes"
  is otherwise just us saying so.
- **`amount.mjs`** is how a price is committed rather than published, so a panel
  can decide whether work was delivered without learning what it cost.

## Checking the contracts yourself

The point of this repository is that you do not have to take our word for any of it.

- **EVM** — Compile with the compiler version in the Sourcify record and compare, or read the verified source at the sourcify URL in deployments/verification.json.
- **Cardano** — aiken build, then blake2b-224 over the compiled script from plutus.json. The result is the on-chain script hash, and needs no third party. This one needs nobody's service at all.
- **Solana** — cargo build-sbf and compare the program bytes against the deployed program id.
- **Sui** — sui move build and compare against the published package.

Every file's SHA-256 is in [`MANIFEST.json`](MANIFEST.json), and the release
digest above is taken over that whole list. A version here names an exact set of
bytes, not a moving branch.

## What this is not

- Not audited. Verified means the deployed bytecode matches this source; it does not mean this source is correct.
- Not the engine. The judge, the console and the protocol implementation are not here.
- Testnet only. No mainnet deployment exists.

## The contracts

- **`evm/JudgeEscrowV1.sol`** — Escrow: funding, submission, provisional verdict, challenge window, finalize, timeout refund.
- **`evm/JudgeFundingVault.sol`** — Funds judge evaluation separately, with a capped platform fee and a timelock on raising it.
- **`evm/JudgeKeyRegistry.sol`** — Which keys may sign a verdict for a given judge.
- **`cardano/judge_escrow.ak`** — Aiken validator, Plutus V3. FinalizeAccept / FinalizeReject / Expire / MutualCancel.
- **`cardano/aiken.toml`** — Build configuration, including the exact stdlib revision the artifact was compiled against.
- **`cardano/plutus.json`** — Compiled blueprint: the script bytes and their hash. blake2b-224 of the script reproduces the on-chain hash.
- **`cardano/script-address.txt`** — The Preprod address the blueprint compiles to.
- **`solana/lib.rs`** — Native Rust program: create-and-fund, submit, record provisional, finalize, expire-and-refund.
- **`solana/Cargo.toml`** — Crate manifest, pinning the toolchain the deployed program was built with.
- **`sui/judge_escrow.move`** — Move module, including the two-step mutual cancel.
- **`sui/Move.toml`** — Package manifest.
- **`midnight/judge_escrow.compact`** — Compact contract with selective disclosure: manifest hash, evidence root and verdict always public; the work, the amount and the parties independently shieldable.
- **`midnight/judge_escrow_bounded.compact`** — The bounded variant: proves a shielded amount is within a PUBLIC cap. One bit reaches the ledger — a refused funding tells an observer the amount exceeded the cap, which is the only inference the design intends to permit.
- **`midnight/judge_predicates.compact`** — Proves a committed measurement satisfies a public condition, publishing only the boolean. 81 and 99 both satisfy 'at least 80' and are indistinguishable on chain.
- **`midnight/judge_registry.compact`** — Many agreements in one long-lived contract, keyed by manifest hash. Every guarantee the single-escrow deployment got from being spent is an assertion here, so registry-sim.mjs attacks them directly.
- **`midnight/judge_multisig.compact`** — m-of-n enforced on chain: m distinct registered finalizers must approve, each in their OWN transaction from their own machine. Nine slots, so 2-of-3, 4-of-6 and 5-of-9 all fit. A counter alone would let one holder approve twice and satisfy a 2-of-3 by themselves.
- **`midnight/contract-info.json`** — The compiler's own statement of what reaches the public ledger, what stays a private witness, and which circuits require a proof.
- **`circuits/predicate.nr`** — Noir: proves a committed measurement satisfies a public threshold. The commitment binding is load-bearing — without it the circuit proves a statement about a number nobody agreed to.
- **`circuits/merkle.nr`** — Noir: proves you know the CONTENT of an item in a committed evidence tree, without revealing which item or where. Takes the content and not the leaf, because a disclosure package hands its recipient the leaves of the items it withheld.
- **`circuits/predicate-vectors.json`** — 16 vectors both the Noir circuit and the TypeScript implementation answer to.
- **`circuits/merkle-vectors.json`** — 7 trees, 30 inclusion cases, odd sizes included — a promoted node contributes no sibling, and a naive implementation drops it and still produces a plausible root.
- **`evm/zk/PredicateVerifier.sol`** — Generated UltraHonk verifier for the predicate circuit, live on Base Sepolia. Its five assembly blocks are annotated memory-safe to compile; that annotation is UNAUDITED.
- **`evm/zk/MerkleVerifier.sol`** — Generated UltraHonk verifier for the membership circuit, live on Base Sepolia. Same unaudited memory-safe annotation.
- **`evm/oracle/WormholeVaaVerifier.sol`** — Recovers Wormhole guardian signatures over a Pyth attestation and refuses anything short of quorum. Before this, 'the guardians signed it' was a claim our adapter made and signed; now a stranger can check the same bytes against a public node with nothing of ours involved.
- **`evm/oracle/guardian-set.json`** — The pinned Wormhole guardian set the verifier is deployed with. Pinned on purpose: a contract accepting whatever set index a VAA declared would accept a set nobody told it about.
- **`tools/verify.js`** — Zero-dependency receipt verifier. Node or a browser, no install. Reports INCOMPLETE where a check could not run — a check that did not happen is never a pass.
- **`tools/README.md`** — How to run the verifier and what each result means.
- **`tools/panel.mjs`** — The panel rules: what makes a quorum valid, and how votes are counted. Published so a tally can be recomputed from the votes without asking our server anything.
- **`tools/canonical.mjs`** — JCS canonical JSON and the domain-separated commitments everything is signed over.
- **`tools/amount.mjs`** — Committed amounts: how a price is hidden from the panel, and how the two parties reproduce the digest.
- **`SCENARIOS.md`** — Every supported combination of decider, privacy, oracle and rail, with what each one costs and what is not built.

## Licence

Apache 2.0. See [`LICENSE`](LICENSE).
