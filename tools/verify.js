/**
 * misharu-verify — a complete receipt verifier in one file, with no dependencies.
 *
 * WHY THIS EXISTS. Until now, checking a Misharu receipt meant cloning the
 * repository and running pnpm. That makes the verifier OUR tool rather than a
 * property of the artifact, and it quietly inverts the whole proposition: a
 * receipt you can only check with the issuer's software is a receipt you are
 * trusting the issuer about.
 *
 * This runs in a browser and in Node with nothing installed. It makes no
 * network call, needs no account, and does not contact Misharu. Everything it
 * needs is in the file you hand it.
 *
 *   node console/verify.js receipt.json
 *   <script type="module"> import { verifyDocument } from "./verify.js" </script>
 *
 * ── WHAT IT CHECKS ───────────────────────────────────────────────────────────
 *
 *   decision record     terms hash to their commitment; the verdict is signed
 *                       by the published key; the signature covers THIS
 *                       manifest and THIS evidence; the stated outcome is the
 *                       signed one; judge runs carry their prompt digest.
 *
 *   disclosure package  each disclosed item's leaf reconstructs the published
 *                       evidence root through its inclusion proof; the package
 *                       accounts for every committed item.
 *
 * ── WHAT IT DOES NOT CHECK ───────────────────────────────────────────────────
 *
 * Whether the judgement was right. Whether the evidence was complete. Whether
 * the key belongs to who you think — pin it yourself against a source you
 * trust. A verifier that implied any of those would be lying.
 *
 * Every unrunnable check reports `not-checked`, which is never a pass.
 */

const enc = new TextEncoder();
const subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;

/* ── RFC 8785 JCS ──────────────────────────────────────────────────────────
 *
 * Reimplemented rather than imported, because importing is the thing this file
 * exists to avoid. It must agree with packages/canonical-json byte for byte —
 * a verifier that canonicalises differently rejects valid receipts, which is
 * worse than not existing. `canonical-json-agreement.test.ts` compares them.
 */
function canonicalize(value, path = "$") {
  if (value === null) return "null";
  const t = typeof value;
  if (t === "boolean") return value ? "true" : "false";
  if (t === "number") {
    if (!Number.isFinite(value)) throw new Error(`non-finite number at ${path}`);
    return JSON.stringify(value);
  }
  if (t === "string") return JSON.stringify(value);
  if (t === "bigint") throw new Error(`bigint at ${path}: represent large integers as strings`);
  if (t === "object") {
    if (Array.isArray(value)) {
      return `[${value.map((v, i) => canonicalize(v === undefined ? null : v, `${path}[${i}]`)).join(",")}]`;
    }
    /** UTF-16 code-unit order, which is ECMAScript's default sort. */
    const keys = Object.keys(value).sort();
    const parts = [];
    for (const k of keys) {
      const v = value[k];
      if (v === undefined) throw new Error(`undefined property at ${path}.${k}`);
      parts.push(`${JSON.stringify(k)}:${canonicalize(v, `${path}.${k}`)}`);
    }
    return `{${parts.join(",")}}`;
  }
  throw new Error(`unsupported type ${t} at ${path}`);
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (s) => new Uint8Array((s.replace(/^sha256:/, "").match(/../g) || []).map((h) => parseInt(h, 16)));
const sha256 = async (bytes) => new Uint8Array(await subtle.digest("SHA-256", bytes));

/** Domain-separated commitment: SHA256( domain || 0x00 || JCS(value) ). */
async function commitment(domain, value) {
  const body = enc.encode(canonicalize(value));
  const prefix = enc.encode(domain);
  const input = new Uint8Array(prefix.length + 1 + body.length);
  input.set(prefix, 0);
  input[prefix.length] = 0x00;
  input.set(body, prefix.length + 1);
  return `sha256:${hex(await sha256(input))}`;
}

const DOMAIN_MANIFEST = "MISHARU/JUDGE-MANIFEST/V1";

/* ── Merkle, matching packages/crypto's profile ─────────────────────────── */
const leafHash = async (bytes) => {
  const i = new Uint8Array(1 + bytes.length);
  i[0] = 0x00; i.set(bytes, 1);
  return sha256(i);
};
const nodeHash = async (l, r) => {
  const i = new Uint8Array(1 + l.length + r.length);
  i[0] = 0x01; i.set(l, 1); i.set(r, 1 + l.length);
  return sha256(i);
};

async function evidenceLeaf(item) {
  return leafHash(enc.encode(canonicalize({ id: item.id, kind: item.kind, content: item.content })));
}

async function proves(leaf, proof, root) {
  let cur = leaf;
  for (const step of proof) {
    const sib = unhex(step.sibling);
    cur = step.side === "right" ? await nodeHash(cur, sib) : await nodeHash(sib, cur);
  }
  return hex(cur) === hex(root);
}

/* ── Ed25519 over a PEM public key ──────────────────────────────────────── */
function pemToDer(pem) {
  const b64 = String(pem).replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = typeof atob === "function"
    ? atob(b64)
    : Buffer.from(b64, "base64").toString("binary");
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

async function verifyEd25519(pem, signatureB64, payload) {
  const der = pemToDer(pem);
  const key = await subtle.importKey("spki", der, { name: "Ed25519" }, false, ["verify"]);
  const sig = typeof atob === "function"
    ? Uint8Array.from(atob(signatureB64), (c) => c.charCodeAt(0))
    : new Uint8Array(Buffer.from(signatureB64, "base64"));
  return subtle.verify({ name: "Ed25519" }, key, sig, enc.encode(canonicalize(payload)));
}

/* ── the two artifact shapes ────────────────────────────────────────────── */

export function detectKind(doc) {
  if (doc && doc.schema && String(doc.schema).includes("/disclosure/")) return "disclosure";
  if (doc && doc.disclosed && doc.evidence_root) return "disclosure";
  /** A verdict that required m of n finalizers is still a decision record. */
  if (doc && (doc.signed_verdict || doc.threshold_verdict)) return "decision";
  if (doc && (doc.provisional_verdict || doc.provisional)) return "escrow";
  return "unknown";
}

async function verifyDecision(doc) {
  const checks = [];
  const add = (check, status, detail) => checks.push({ check, status, detail });

  const recomputed = await commitment(DOMAIN_MANIFEST, doc.manifest);
  add("manifest_hash_matches", recomputed === doc.manifest_hash ? "pass" : "fail",
    `computed ${recomputed.slice(0, 26)}…`);

  /**
   * A threshold verdict, when the agreement demanded one.
   *
   * This was added to the repository's verifier first and not here, and a
   * threshold receipt promptly failed as "not a recognised shape" — verifying
   * for us and not for the stranger who downloaded this file, which is the one
   * outcome that makes a portable verifier worthless.
   */
  if (doc.threshold_verdict) {
    const tv = doc.threshold_verdict;
    const policy = tv.policy || {};
    const at = tv.decided_at ? new Date(tv.decided_at) : new Date();
    const byId = new Map((policy.keys || []).map((k) => [k.key_id, k]));

    /** Counted per DISTINCT key: two signatures from one holder is one vote. */
    const valid = new Set();
    const seen = new Set();
    for (const sig of tv.signatures || []) {
      if (sig.algorithm !== "Ed25519") continue;
      if (seen.has(sig.value)) continue;
      seen.add(sig.value);
      const k = byId.get(sig.key_id);
      if (!k) continue;
      if (k.valid_from && at < new Date(k.valid_from)) continue;
      if (k.valid_to && at >= new Date(k.valid_to)) continue;
      let ok = false;
      try { ok = await verifyEd25519(k.public_key_pem, sig.value, tv.payload); } catch { ok = false; }
      if (ok) valid.add(sig.key_id);
    }
    const met = valid.size >= (policy.m || Infinity);
    add("threshold_met", met ? "pass" : "fail",
      `${valid.size} distinct valid signer(s) of ${(policy.keys || []).length}, ${policy.m} required`);

    const p = tv.payload || {};
    add("verdict_binds_the_manifest", p.manifest_hash === doc.manifest_hash ? "pass" : "fail",
      `verdict binds ${String(p.manifest_hash).slice(0, 26)}…`);
    const r0 = doc.evidence_bundle && doc.evidence_bundle.evidence_root;
    add("verdict_binds_the_evidence_root", p.evidence_root === r0 ? "pass" : "fail",
      `verdict binds ${String(p.evidence_root).slice(0, 26)}…`);
    const s0 = doc.aggregation && doc.aggregation.outcome;
    add("recorded_outcome_matches_the_signed_one", !s0 || s0 === p.outcome ? "pass" : "fail",
      `record says ${s0}, the signatures cover ${p.outcome}`);

    /**
     * Never a pass. A 2-of-3 receipt over an escrow that checks one signature
     * has documented the single point of failure, not removed it.
     */
    add("on_chain_requirement_is_weaker", "not-checked",
      `this receipt required ${policy.m}-of-${(policy.keys || []).length}, but the settlement chains check `
      + "ONE signature each — a key holder can still move funds alone; what they cannot do is produce a "
      + "receipt that verifies. Detectable, not prevented.");

    const it0 = doc.evidence_bundle && doc.evidence_bundle.items;
    add("evidence_supports_selective_disclosure", it0 && it0.length > 0 ? "pass" : "not-checked",
      it0 && it0.length > 0 ? `${it0.length} committed items` : "no item list published");
    return { checks, valid: checks.every((c) => c.status !== "fail") };
  }

  const env = doc.signed_verdict;
  const pem = doc.keys && doc.keys.finalizer_public_key_pem;
  if (!env) { add("verdict_is_signed", "fail", "no signed verdict"); return { checks, valid: false }; }
  if (!pem) {
    /** Not a bad signature — nothing to check it against. Different failure, different message. */
    add("finalizer_public_key_published", "fail", "no public key in the record; nobody can check the signature");
    return { checks, valid: false };
  }
  add("finalizer_public_key_published", "pass", (doc.keys.finalizer_key_id || "(unnamed key)"));

  let sigOk = false, detail = "Ed25519 over the canonical verdict payload";
  try { sigOk = await verifyEd25519(pem, env.signature.value, env.payload); }
  catch (e) { detail = `the published key could not be read: ${String(e.message).slice(0, 70)}`; }
  add("verdict_signature_verifies", sigOk ? "pass" : "fail", detail);

  const p = env.payload || {};
  add("verdict_binds_the_manifest", p.manifest_hash === doc.manifest_hash ? "pass" : "fail",
    `verdict binds ${String(p.manifest_hash).slice(0, 26)}…`);
  const root = doc.evidence_bundle && doc.evidence_bundle.evidence_root;
  add("verdict_binds_the_evidence_root", p.evidence_root === root ? "pass" : "fail",
    `verdict binds ${String(p.evidence_root).slice(0, 26)}…`);
  const stated = doc.aggregation && doc.aggregation.outcome;
  add("recorded_outcome_matches_the_signed_one", !stated || stated === p.outcome ? "pass" : "fail",
    `record says ${stated}, the signature covers ${p.outcome}`);

  const runs = doc.judge_runs_detail || [];
  if (runs.length === 0) {
    add("judge_runs_are_auditable", "not-checked", "no judge runs recorded — rules-only, or runs not kept");
  } else {
    const bad = runs.filter((r) => !(r.prompt && r.prompt.rendered_prompt_hash)
      || !(r.bindings && r.bindings.manifest_hash === doc.manifest_hash && r.bindings.evidence_root === root));
    add("judge_runs_are_auditable", bad.length === 0 ? "pass" : "fail",
      bad.length === 0 ? `${runs.length} run(s) carry a prompt digest and bind this case`
        : `${bad.length} run(s) lack a prompt digest or bind another case`);
  }

  /** Escalation, when present, must have been bounded and must not have been requested by a party. */
  if (doc.escalation) {
    const e = doc.escalation;
    const bounded = e.policy && Number.isInteger(e.policy.max_rounds) && e.policy.max_rounds <= 5;
    add("escalation_was_bounded", bounded ? "pass" : "fail",
      bounded ? `max ${e.policy.max_rounds} round(s), ${(e.rounds || []).length - 1} used`
        : "the escalation policy has no usable bound");
    const consistent = !e.exhausted || (doc.aggregation && doc.aggregation.outcome === "INDETERMINATE");
    add("exhausted_escalation_is_undecided", consistent ? "pass" : "fail",
      consistent ? "exhaustion resolves to INDETERMINATE, as it must"
        : "escalation exhausted but the record claims a decided outcome");
  }

  const items = doc.evidence_bundle && doc.evidence_bundle.items;
  add("evidence_supports_selective_disclosure", items && items.length > 0 ? "pass" : "not-checked",
    items && items.length > 0 ? `${items.length} committed items` : "no item list; the only disclosure is everything");

  return { checks, valid: checks.every((c) => c.status !== "fail") };
}

async function verifyDisclosure(doc, expectedRoot, committedIds) {
  const checks = [];
  const add = (check, status, detail) => checks.push({ check, status, detail });
  const norm = (r) => String(r || "").replace(/^sha256:/, "").toLowerCase();

  if (expectedRoot) {
    add("root_matches_the_published_one", norm(doc.evidence_root) === norm(expectedRoot) ? "pass" : "fail",
      `package ${norm(doc.evidence_root).slice(0, 20)}… / supplied ${norm(expectedRoot).slice(0, 20)}…`);
  } else {
    /**
     * The most important caveat in this file. Checking a package against its
     * own claimed root proves only that the package is self-consistent, which
     * a forger arranges trivially.
     */
    add("root_matches_the_published_one", "not-checked",
      "NOT CHECKED: no independent root supplied. Paste the root from the receipt or the chain — a package "
      + "checked against its own root proves nothing");
  }

  const root = unhex(norm(expectedRoot || doc.evidence_root));
  const disclosed = doc.disclosed || [];
  if (disclosed.length === 0) add("discloses_something", "fail", "the package reveals no items");

  for (const item of disclosed) {
    let ok = false;
    try { ok = await proves(await evidenceLeaf(item), item.proof || [], root); } catch { ok = false; }
    add(`item_${item.id}_is_in_the_committed_evidence`, ok ? "pass" : "fail",
      ok ? "its inclusion proof reconstructs the root" : "the inclusion proof does not reconstruct the root");
  }

  const total = doc.total_items;
  const accounted = disclosed.length + (doc.withheld_ids || []).length;
  add("item_count_is_internally_consistent", total === accounted ? "pass" : "fail",
    `${total} total, ${disclosed.length} disclosed + ${(doc.withheld_ids || []).length} withheld`);

  if (committedIds && committedIds.length) {
    const claimed = [...disclosed.map((d) => d.id), ...(doc.withheld_ids || [])].sort();
    const expected = [...committedIds].sort();
    const same = claimed.length === expected.length && claimed.every((id, i) => id === expected[i]);
    add("accounts_for_every_committed_item", same ? "pass" : "fail",
      same ? `all ${expected.length} committed items accounted for`
        : `the case committed ${expected.length}; this package accounts for ${claimed.length}`);
  } else {
    add("accounts_for_every_committed_item", "not-checked",
      "NOT CHECKED: no committed item list supplied, so this package could omit items undetected");
  }

  /**
   * For a disclosure package, `not-checked` on the root or the completeness
   * check must NOT read as VALID.
   *
   * The first version reported VALID for a package whose root had never been
   * independently checked — the single most misleading thing this file could
   * say, since checking a package against its own root proves nothing. The
   * repo verifier already refused that; the standalone one disagreed, which is
   * exactly the divergence a second implementation exists to avoid.
   */
  const critical = ["root_matches_the_published_one", "accounts_for_every_committed_item"];
  const unchecked = checks.filter((c) => critical.includes(c.check) && c.status === "not-checked");
  return {
    checks,
    valid: checks.every((c) => c.status !== "fail") && unchecked.length === 0,
    incomplete: unchecked.map((c) => c.check),
  };
}

/**
 * Verify whatever you were handed.
 *
 * `expectedRoot` and `committedIds` are the values a recipient should take from
 * the receipt or the chain — never from the package being checked.
 */
export async function verifyDocument(doc, opts = {}) {
  if (!subtle) throw new Error("no WebCrypto available; Node 18+ or a modern browser is required");
  const kind = detectKind(doc);
  if (kind === "decision") return { kind, ...(await verifyDecision(doc)) };
  if (kind === "disclosure") return { kind, ...(await verifyDisclosure(doc, opts.expectedRoot, opts.committedIds)) };
  if (kind === "escrow") {
    return { kind, valid: false, checks: [{ check: "supported_shape", status: "not-checked",
      detail: "This is an escrow case bundle with a provisional/final verdict pair. Its signature checks need "
        + "the full receipt package: pnpm verify <file>. This standalone verifier covers decision records and "
        + "disclosure packages." }] };
  }
  return { kind, valid: false, checks: [{ check: "recognised_shape", status: "fail",
    detail: "not a decision record, a disclosure package, or an escrow bundle" }] };
}

/* ── Node entrypoint ────────────────────────────────────────────────────── */
if (typeof process !== "undefined" && process.argv && process.argv[1]
    && process.argv[1].endsWith("verify.js")) {
  const { readFileSync } = await import("node:fs");
  const path = process.argv[2];
  if (!path) { console.error("usage: node verify.js <file.json> [--root sha256:…]"); process.exit(2); }
  const rootArg = process.argv.indexOf("--root");
  const doc = JSON.parse(readFileSync(path, "utf8"));
  const r = await verifyDocument(doc, { expectedRoot: rootArg > -1 ? process.argv[rootArg + 1] : undefined });
  console.log(`\n  ${path} — ${r.kind}\n`);
  for (const c of r.checks) console.log(`  ${c.status.padEnd(11)} ${c.check}\n      ${c.detail}`);
  const n = (s) => r.checks.filter((c) => c.status === s).length;
  /**
   * INVALID and INCOMPLETE are different answers and must not share a word.
   * "A check failed" means the artifact is wrong. "A check could not run" means
   * you have not been given enough to judge — usually the independent root.
   * Collapsing them tells an honest reader their good receipt is forged.
   */
  const verdict = n("fail") > 0 ? "INVALID" : r.valid ? "VALID" : "INCOMPLETE";
  console.log(`\n  ${verdict} — ${n("pass")} passed, ${n("fail")} failed, ${n("not-checked")} not checked`);
  if (verdict === "INCOMPLETE") {
    console.log(`  nothing failed, but ${(r.incomplete || []).join(", ")} could not be checked.`);
    console.log(`  supply the root from the receipt or the chain:  --root sha256:…`);
  }
  console.log("");
  process.exit(verdict === "VALID" ? 0 : 1);
}
