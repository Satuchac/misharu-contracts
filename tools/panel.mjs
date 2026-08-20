import { commitment, verifyEnvelope, DOMAINS } from "./canonical.mjs";

/**
 * Panel rules — the single definition, shared by the console and the verifier.
 *
 * WHY THIS FILE IS HERE AND NOT IN packages/.
 *
 * The console is deliberately standalone: `server.mjs` imports nothing outside
 * its own directory, because the deployed host has no checkout. A rule living
 * in `packages/judge-core` could not be reached from there.
 *
 * And it has to be ONE rule. If the console accepted a panel the tally later
 * rejected, an agreement could be funded that nothing could ever settle; if it
 * accepted one the tally counted DIFFERENTLY, two readers would disagree about
 * who was paid. `packages/judge-core/src/panel.ts` imports this file rather
 * than restating it — the ledger decoder, the case bundles and the served
 * verifier all drifted by being written twice, and this is the security-
 * critical one.
 *
 * Pure functions, no dependencies, so both sides can use it unchanged.
 */

/**
 * Is this panel one that can produce an unambiguous answer?
 *
 * ── THE QUORUM MUST BE A MAJORITY ───────────────────────────────────────────
 *
 * `quorum > signers/2`, and this looks like an arbitrary restriction but is
 * not. Take 2-of-4: two signers vote to release while two vote to refund, and
 * BOTH thresholds are met at once. The escrow would be told to pay the provider
 * and refund the buyer, and which one happened would depend on the order the
 * votes arrived — that is, on the relay, not on the panel.
 *
 * A majority quorum makes that structurally impossible, because two disjoint
 * majorities cannot exist. 3-of-5 is fine, 2-of-3 is fine, 2-of-4 is refused.
 * Refusing at configuration time is far better than discovering it once the
 * money is in, and far better than inventing a tie-break nobody agreed to.
 */
export function validatePanel(panel) {
  if (!panel || !Array.isArray(panel.signers)) return "a panel needs a list of signers";
  const n = panel.signers.length;
  if (n < 2) return "a panel of fewer than two signers is a single judge with extra steps";
  if (!Number.isInteger(panel.quorum) || panel.quorum < 1) return "the quorum must be a positive integer";
  if (panel.quorum > n) return `a quorum of ${panel.quorum} can never be met by ${n} signers`;
  if (panel.quorum * 2 <= n) {
    return `a quorum of ${panel.quorum} of ${n} allows two opposing majorities at once `
      + `(${panel.quorum} for and ${panel.quorum} against), so the outcome would depend on which votes `
      + `arrived first — use at least ${Math.floor(n / 2) + 1}`;
  }

  const ids = panel.signers.map((s) => s?.id);
  if (ids.some((i) => !i)) return "every signer needs an id";
  if (new Set(ids).size !== ids.length) {
    /** The failure that turns m-of-n into 1-of-n while still reading as m-of-n. */
    return "the same signer id appears more than once";
  }

  /**
   * Distinct ids are not enough — the same KEY under two ids is the same
   * failure wearing a different label, and it is the easier one to arrange.
   */
  const material = panel.signers.map((s) => {
    const k = s?.key ?? {};
    if (k.scheme === "ed25519") return k.key_id ? `ed25519:${k.key_id}` : null;
    if (k.scheme === "wallet") return k.chain && k.address ? `wallet:${k.chain}:${String(k.address).toLowerCase()}` : null;
    return null;
  });
  if (material.some((m) => !m)) return "every signer needs key material the counterparty can check";
  if (new Set(material).size !== material.length) {
    return "two signers share the same key, so one holder would satisfy the quorum alone";
  }

  for (const s of panel.signers) {
    if (s.kind !== "human" && s.kind !== "agent") return `signer "${s.id}" must be a human or an agent`;
    if (s.kind === "agent" && !s.judge?.id) {
      /** Naming a model without pinning its configuration is agreeing to instructions that can be rewritten. */
      return `agent signer "${s.id}" must name the judge it runs, and its version`;
    }
    if (s.kind === "agent" && s.key.scheme !== "ed25519") {
      return `agent signer "${s.id}" must hold an ed25519 attestation key`;
    }
    /**
     * Optional, and committed when present: the seat's Midnight public key.
     *
     * The ZK rail enforces the quorum on chain, and Compact derives a seat's
     * identity from a secret this protocol's other keys cannot produce. So a
     * seat that wants its vote enforced on chain — rather than merely recorded
     * in a receipt — registers a Midnight public key here, and it goes into the
     * agreement hash with everything else.
     *
     * A seat without one still votes; its vote is verifiable by anyone offline.
     * What it cannot do is be one of the approvals the ZK escrow counts, and
     * `scripts/panel-settle-zk.ts` refuses rather than substituting a key it
     * generated itself — an on-chain quorum met by keys the deployer minted is
     * not a quorum, it is one machine wearing three hats.
     */
    if (s.midnight_public_key !== undefined && s.midnight_public_key !== null
      && !/^[0-9a-f]{64}$/.test(String(s.midnight_public_key))) {
      return `signer "${s.id}" has a malformed Midnight public key — expected 32 bytes as hex`;
    }
    /**
     * Optional, and committed when present: the seat's X25519 key for RECEIVING
     * the sealed deliverable.
     *
     * A third key, deliberately. This one is used to decrypt, the ed25519 key
     * signs, and the Midnight key proves identity to a circuit. Ed25519 can be
     * converted to X25519 and it would save a registration step; it would also
     * be using one key for two primitives, which is the kind of shortcut that
     * turns a signature oracle into a decryption oracle.
     *
     * A seat without one cannot be sealed to, and `seal()` refuses rather than
     * skipping it — a member who cannot open the evidence is a judge who cannot
     * see the case they are voting on.
     */
    if (s.sealing_public_key !== undefined && s.sealing_public_key !== null
      && !/^-----BEGIN PUBLIC KEY-----/.test(String(s.sealing_public_key))) {
      return `signer "${s.id}" has a malformed sealing key — expected an X25519 public key in PEM`;
    }
  }
  if (panel.deadline_seconds !== undefined && panel.deadline_seconds !== null
    && (!Number.isInteger(panel.deadline_seconds) || panel.deadline_seconds <= 0)) {
    return "a deadline, if given, must be a positive whole number of seconds";
  }
  return null;
}

/**
 * The panel exactly as it goes into the agreement hash.
 *
 * Field order fixed and derived values excluded, so two parties serialising the
 * same panel compute the same digest. Everything here is material: change a
 * member, a key, a pinned judge version or the quorum, and the hash moves.
 */
export function canonicalPanel(panel) {
  return {
    quorum: panel.quorum,
    deadline_seconds: panel.deadline_seconds ?? null,
    signers: panel.signers.map((s) => ({
      id: s.id,
      kind: s.kind,
      key: s.key.scheme === "ed25519"
        ? { scheme: "ed25519", key_id: s.key.key_id, public_key_pem: s.key.public_key_pem }
        : { scheme: "wallet", chain: s.key.chain, address: String(s.key.address).toLowerCase() },
      judge: s.judge ? { id: s.judge.id, version: s.judge.version ?? null } : null,
      /** Committed, so the on-chain seat cannot be swapped after signing. */
      midnight_public_key: s.midnight_public_key ?? null,
      /** Committed, so the audience for the sealed work is fixed before the money moves. */
      sealing_public_key: s.sealing_public_key ?? null,
    })),
  };
}

/**
 * The exact bytes a signer must sign, so the console and the offline verifier
 * cannot disagree about what a vote covers.
 *
 * A wallet signer signs THIS digest; an agent signs the payload with its
 * attestation key and the envelope carries the signature. Either way the thing
 * committed to is the same canonical serialisation.
 */
export function voteDigest(vote) {
  return commitment(DOMAINS.PANEL_VOTE, vote);
}

/**
 * Count the votes.
 *
 * Returns INDETERMINATE unless a quorum agrees — including when the panel is
 * merely split or short of votes. That is deliberate, and it is the property
 * the whole escrow rests on: an undecided panel must pay nobody. Turning "we
 * could not agree" into a payment is the worst bug available here, so there is
 * no default outcome, no tie-break, and no "the buyer wins if unsure".
 *
 * `verifyWallet` is injected because verifying a wallet signature means
 * deriving an address from a recovered key, per chain, and that lives in
 * console/wallet-auth.mjs. Without it, wallet seats are refused rather than
 * trusted — a vote nobody checked must never be counted.
 */
export function tallyPanel({ votes, panel, manifestHash, evidenceRoot, at, verifyWallet }) {
  const checks = [];
  const add = (check, ok, detail) => checks.push({ check, ok, detail });
  const disqualified = [];
  const out = (outcome, accept = [], reject = []) => ({
    outcome, accept, reject, disqualified,
    quorum: panel?.quorum ?? 0, panel_size: panel?.signers?.length ?? 0, checks,
  });

  const bad = validatePanel(panel);
  if (bad) { add("panel_is_valid", false, bad); return out("INDETERMINATE"); }
  add("panel_is_valid", true, `${panel.quorum} of ${panel.signers.length}`);

  const byId = new Map(panel.signers.map((s) => [s.id, s]));
  const list = Array.isArray(votes) ? votes : [];

  /**
   * Equivocation is settled before counting, not during.
   *
   * A signer who signs both ACCEPT and REJECT over the same evidence has not
   * cast a vote — they have produced proof that their vote means nothing. If we
   * counted the first and ignored the rest, a malicious signer could send YES
   * to one relay and NO to another and let arrival order decide the case. Both
   * are discarded and the signer is named.
   */
  const seen = new Map();
  for (const env of list) {
    const v = env?.payload;
    if (!v?.signer_id) continue;
    if (v.manifest_hash !== manifestHash || v.evidence_root !== evidenceRoot) continue;
    if (!seen.has(v.signer_id)) seen.set(v.signer_id, new Set());
    seen.get(v.signer_id).add(v.outcome);
  }
  const equivocators = new Set([...seen.entries()].filter(([, o]) => o.size > 1).map(([id]) => id));
  for (const id of equivocators) {
    disqualified.push({ signer_id: id, reason: "signed both ACCEPT and REJECT over the same evidence" });
  }
  add("no_equivocation", equivocators.size === 0,
    equivocators.size ? `${[...equivocators].join(", ")} signed contradictory votes`
      : "no signer contradicted itself");

  const counted = new Map();
  for (const env of list) {
    const v = env?.payload;
    const refuse = (reason) => disqualified.push({ signer_id: v?.signer_id ?? "(unnamed)", reason });

    if (!v || !v.signer_id) { refuse("a vote with no signer"); continue; }
    if (equivocators.has(v.signer_id)) continue; // already recorded once

    const signer = byId.get(v.signer_id);
    if (!signer) { refuse("not a member of the panel this agreement committed to"); continue; }

    /** The binding. A vote is about ONE agreement and ONE delivery, or it is not a vote. */
    if (v.manifest_hash !== manifestHash) { refuse("cast over a different agreement"); continue; }
    if (v.evidence_root !== evidenceRoot) { refuse("cast over different evidence than the one being settled"); continue; }
    if (v.outcome !== "ACCEPT" && v.outcome !== "REJECT") { refuse(`"${v.outcome}" is not a vote`); continue; }

    const votedAt = Date.parse(v.voted_at);
    if (!Number.isFinite(votedAt)) { refuse("no readable vote time"); continue; }
    if (votedAt > at.getTime()) { refuse("cast after the moment being settled"); continue; }

    let ok = false;
    if (signer.key.scheme === "ed25519") {
      ok = verifyEnvelope(env, signer.key.public_key_pem);
      if (!ok) refuse("the signature does not check out against the registered key");
    } else if (typeof verifyWallet !== "function") {
      refuse("this panel has wallet signers but no wallet verifier was supplied");
    } else {
      ok = verifyWallet({
        chain: signer.key.chain, address: signer.key.address,
        digest: voteDigest(v), signature: String(env?.signature ?? ""),
      }) === true;
      if (!ok) refuse("the wallet signature does not check out for the registered address");
    }
    if (!ok) continue;

    /**
     * One vote per signer. `counted` is keyed by signer, so a signer sending
     * the same vote twice adds nothing — the arithmetic that turns 3-of-5 into
     * 1-of-5 if you count messages instead of members.
     */
    counted.set(v.signer_id, v.outcome);
  }

  const accept = [...counted.entries()].filter(([, o]) => o === "ACCEPT").map(([id]) => id).sort();
  const reject = [...counted.entries()].filter(([, o]) => o === "REJECT").map(([id]) => id).sort();
  add("distinct_signers_counted", true, `${counted.size} of ${panel.signers.length} voted`);

  if (accept.length >= panel.quorum) {
    add("quorum_reached", true, `${accept.length} of ${panel.signers.length} to release, quorum ${panel.quorum}`);
    return out("ACCEPT", accept, reject);
  }
  if (reject.length >= panel.quorum) {
    add("quorum_reached", true, `${reject.length} of ${panel.signers.length} to refund, quorum ${panel.quorum}`);
    return out("REJECT", accept, reject);
  }
  add("quorum_reached", false,
    `${accept.length} to release, ${reject.length} to refund, ${panel.quorum} needed — nobody is paid on this`);
  return out("INDETERMINATE", accept, reject);
}
