# Tools

Standalone utilities you can run without the rest of this repository.

---

## `verify.js` — check a Misharu receipt yourself

One file. **No dependencies, no install, no network, no account.** It does not
contact Misharu and never sends your document anywhere.

That is the point. A receipt you can only check with the issuer's software is a
receipt you are trusting the issuer about.

### Get it

```bash
curl -O https://misharu.176-102-64-240.sslip.io/verify.js
```

Or download it from the **Verify a receipt** tab in the console, or copy it out
of this directory. It is ~16 KB of plain JavaScript — read it before you run it.

### Use it

```bash
node tools/verify.js receipt.json
```

For a **disclosure package**, supply the evidence root independently — from the
receipt it belongs to, or from the chain:

```bash
node tools/verify.js disclosure.json --root sha256:581a5e74e54d6e72…
```

Requires Node 18+ or any modern browser. Nothing else.

### In a browser

```html
<script type="module">
  import { verifyDocument } from "./verify.js";
  const result = await verifyDocument(JSON.parse(text), {
    expectedRoot: "sha256:…",   // from the receipt or the chain
    committedIds: ["po", "line-1"],
  });
  console.log(result.valid, result.checks);
</script>
```

The console's Verify tab is exactly this, with a textarea around it.

### What it tells you

Three verdicts, and the difference between the last two matters:

| | meaning |
|---|---|
| **VALID** | every check ran and passed |
| **INVALID** | a check **failed** — the artifact does not hold up |
| **INCOMPLETE** | nothing failed, but a check **could not run** — usually because you did not supply the independent evidence root |

`INCOMPLETE` is not a soft pass. A disclosure package checked against its own
claimed root proves only that it is internally consistent, which anyone forging
one would arrange. Supply the root from a source you trust, or the answer is
"not enough information" rather than "fine".

### What it checks

**Decision records** — a judgement with no escrow and no chain:

- the published terms hash to the commitment in the record
- the verdict is signed by the key the record publishes
- that signature covers **this** manifest and **this** evidence, not another case
- the outcome shown is the outcome signed
- every judge run carries the exact prompt's digest and binds this case
- if the panel escalated: rounds were bounded, and exhaustion resolved to
  INDETERMINATE rather than to a majority

**Disclosure packages** — part of the evidence shown to one party:

- each disclosed item's leaf reconstructs the published evidence root through
  its inclusion proof
- the package accounts for every item the case committed, so a partial
  disclosure cannot pass as a complete one

### What it does not check

- **Whether the judgement was right.** The record lets you disagree with
  reasoning you can see. It does not make the reasoning correct.
- **Whether the evidence was complete** — only that these items are what was
  judged.
- **Whether the key belongs to who you think.** Pin it yourself against a source
  you trust: `/api/keys`, or `deployments/finalizer-key.json`.
- **Escrow case bundles** with a provisional/final verdict pair. Those need the
  full receipt package (`pnpm verify <file>`); this file covers decision records
  and disclosure packages.

A verifier that implied any of the above would be lying about what a signature
can do.

### Exit codes

`0` valid · `1` invalid or incomplete · `2` unusable input

Non-zero on anything short of VALID, so it works in CI.

### A note on trust

This file reimplements RFC 8785 canonicalisation rather than importing ours,
because importing is what it exists to avoid. Two implementations can drift, and
a verifier that disagrees with the issuer would tell an honest reader their
genuine receipt is forged — so `packages/canonical-json/src/standalone-agreement.test.ts`
compares them on every build.
