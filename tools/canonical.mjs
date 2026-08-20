/**
 * Canonical JSON and the primitives built on it, for the standalone console.
 *
 * WHY THIS EXISTS SEPARATELY FROM packages/crypto.
 *
 * The console imports nothing outside its own directory — the deployed host has
 * no checkout — so it cannot use the TypeScript implementation. That leaves two
 * implementations of the same rule, which is the arrangement this repository has
 * been burned by more than once.
 *
 * The answer is not to pretend there is one. It is to make them answer to the
 * same third thing: `canonical-agreement.test.ts` runs a corpus of awkward
 * values through both and asserts byte equality. Two implementations, one
 * corpus — the same shape as the Merkle vectors.
 *
 * This matters more now than it did. A panel vote is signed over these bytes by
 * a wallet or an attestation key, verified here at ingest, and verified again by
 * the offline receipt verifier. If the two serialisations disagreed, a vote
 * would count in one place and not the other, and the two readers would
 * disagree about who was paid.
 */
import { createHash, verify as verifySignature, createPublicKey } from "node:crypto";

/**
 * Keys sorted at every level so two parties serialising the same value compute
 * the same digest. A hash that depended on key order would let one side sign a
 * document the other could not reproduce.
 *
 * ── WHY UNDEFINED THROWS ────────────────────────────────────────────────────
 *
 * This used to coerce `undefined` to `null`, and `packages/canonical-json`
 * refuses it outright — a divergence the corpus test found the moment the two
 * were compared. The strict side is correct: JCS has no representation for
 * undefined, so the choice is between refusing and silently changing the shape
 * of what gets signed. Silently changing it is how a signer and a verifier end
 * up disagreeing about whether a field existed at all, and a panel vote is
 * exactly the kind of document where that would decide who was paid.
 *
 * Arrays are the documented exception, matching JCS and the package: a hole in
 * an array HAS a position, so it becomes null rather than vanishing and
 * shifting every index after it.
 */
export class CanonicalizationError extends Error {}

export function canonical(value, path = "$") {
  if (value === undefined) {
    throw new CanonicalizationError(`Cannot canonicalize undefined at ${path}`);
  }
  if (value === null) return "null";
  if (typeof value === "bigint") {
    throw new CanonicalizationError(`BigInt at ${path}: represent large integers as strings`);
  }
  if (Array.isArray(value)) {
    return `[${value
      .map((item, i) => canonical(item === undefined ? null : item, `${path}[${i}]`))
      .join(",")}]`;
  }
  if (typeof value === "object") {
    const keys = Object.keys(value).sort(); // UTF-16 code unit order per JCS
    const parts = [];
    for (const key of keys) {
      const v = value[key];
      if (v === undefined) {
        throw new CanonicalizationError(
          `Undefined property value at ${path}.${key}; omit the key or use null explicitly`);
      }
      parts.push(`${JSON.stringify(key)}:${canonical(v, `${path}.${key}`)}`);
    }
    return `{${parts.join(",")}}`;
  }
  if (typeof value === "number" || typeof value === "string" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  throw new CanonicalizationError(`Unsupported type ${typeof value} at ${path}`);
}

export const canonicalBytes = (value) => Buffer.from(canonical(value), "utf8");

/** `sha256:<hex>`. The prefix is mandatory everywhere in this protocol. */
export const sha256Hex = (bytes) => createHash("sha256").update(bytes).digest("hex");

/**
 * A domain-separated commitment: SHA-256(domain || 0x00 || canonical(value)).
 *
 * The separator is a zero byte, not a colon or a slash, so no domain name can
 * ever be a prefix of another and produce the same input.
 */
export function commitment(domain, value) {
  const body = canonicalBytes(value);
  const prefix = Buffer.from(domain, "utf8");
  const input = Buffer.concat([prefix, Buffer.from([0]), body]);
  return `sha256:${sha256Hex(input)}`;
}

/** The domains this console commits under. Must match packages/crypto exactly. */
export const DOMAINS = {
  AMOUNT: "MISHARU/AMOUNT/V1",
  PANEL: "MISHARU/PANEL/V1",
  PANEL_VOTE: "MISHARU/PANEL-VOTE/V1",
};

/**
 * Verify an Ed25519 envelope against a registered public key.
 *
 * The bytes signed are the canonical serialisation of the PAYLOAD, never the
 * envelope — signing the envelope would make the signature cover itself.
 */
export function verifyEnvelope(envelope, publicKeyPem) {
  try {
    if (!envelope?.payload || envelope?.signature?.algorithm !== "Ed25519") return false;
    const value = envelope.signature.value;
    if (typeof value !== "string" || !value) return false;
    return verifySignature(
      null,
      canonicalBytes(envelope.payload),
      createPublicKey(publicKeyPem),
      Buffer.from(value, "base64"),
    );
  } catch {
    /** A malformed key or signature is a failed verification, not a crash. */
    return false;
  }
}
