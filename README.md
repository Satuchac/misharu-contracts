# Misharu contracts

**Version 0.1.0** · release digest `sha256:8a181a4bb22f03d265c7b1f09ecc5a4edcebf8c3e36cd9704c2a48015c005943`

The deployed escrow contracts behind [Misharu](https://misharu.176-102-64-240.sslip.io),
their compiled artifacts, the addresses they run at, and the evidence that the
deployed bytecode matches this source.

The adjudication engine is not in this repository. These are the contracts, so
that anyone settling through them — or reviewing a claim that they exist — can
read exactly what is running.

## What is deployed

| Rail | Contract | Address | Verified |
|---|---|---|---|
| Base Sepolia | Judge escrow | `0xcD0b89BBB07B614E45c78B3C55d24e48E7F6EC81` | [exact_match](https://sourcify.dev/#/lookup/0xcD0b89BBB07B614E45c78B3C55d24e48E7F6EC81) |
| Base Sepolia | Judge key registry | `0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17` | [exact_match](https://sourcify.dev/#/lookup/0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17) |
| Base Sepolia | Judge funding vault | `0xae8D16Dc169F9512233AA53BFe9BaB91485A55b7` | [exact_match](https://sourcify.dev/#/lookup/0xae8D16Dc169F9512233AA53BFe9BaB91485A55b7) |
| Base Sepolia | Demo escrow | `0x386E4A8caccad480FEa8D4611F9b365879cba218` | [exact_match](https://sourcify.dev/#/lookup/0x386E4A8caccad480FEa8D4611F9b365879cba218) |
| Ethereum Sepolia | Judge escrow | `0x89c5EA82daD056Edf7c95DBC52a1A5Be3b10D0D9` | [exact_match](https://sourcify.dev/#/lookup/0x89c5EA82daD056Edf7c95DBC52a1A5Be3b10D0D9) |
| Ethereum Sepolia | Judge key registry | `0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17` | [exact_match](https://sourcify.dev/#/lookup/0x5c4E6dC4EEaB8747C5ef34B916aCFF629a83Df17) |
| Ethereum Sepolia | Demo escrow | `0x9e1F8018587b96e9637dF7159Aed26eB855C7c35` | [exact_match](https://sourcify.dev/#/lookup/0x9e1F8018587b96e9637dF7159Aed26eB855C7c35) |

Cardano, Solana and Sui deployments are listed in [`deployments/registry.json`](deployments/registry.json).

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

## Licence

Apache 2.0. See [`LICENSE`](LICENSE).
