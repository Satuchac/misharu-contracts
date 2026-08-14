# Misharu contracts

**Version 0.2.0** · release digest `sha256:6581e8007493242e561216b873bd1081afd5bbf87204a2eb38e99d672a5a80c2`

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
| Midnight Preprod | Judge escrow (Compact, ZK) | — | compiled, not deployed | — |

**The Cardano validator carries the strongest claim here.** blake2b-224 over the
compiled script in [`cardano/plutus.json`](cardano/plutus.json) reproduces the
on-chain script hash — so it can be checked without Sourcify, without us, and
without any service being online. The EVM contracts rely on Sourcify having
recompiled and compared; Solana and Sui rely on you building the published
source yourself.

**Midnight is not deployed.** It is included because the privacy design is worth
reading and because when it does deploy, only its status column changes.

## Checking it yourself

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
- **`midnight/judge_escrow.compact`** — Compact contract with selective disclosure: manifest hash, evidence root and verdict always public; the work, the amount and the parties independently shieldable. NOT DEPLOYED.
- **`midnight/contract-info.json`** — The compiler's own statement of what reaches the public ledger, what stays a private witness, and which circuits require a proof.

## Licence

Apache 2.0. See [`LICENSE`](LICENSE).
