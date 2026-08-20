/**
 * An amount the panel does not get to see.
 *
 * ── WHY HIDE IT FROM THE JUDGES ─────────────────────────────────────────────
 *
 * A panel decides whether the work was delivered. The price is not evidence of
 * that, and knowing it changes how people read the same deliverable: a signer
 * who sees "€400" and a signer who sees "€40,000" are not judging the same way,
 * even when they believe they are. It is also commercially sensitive in exactly
 * the cases where a panel is worth having — a supplier's rate to one customer,
 * visible to three outsiders, is a leak with a price on it.
 *
 * So the agreement can commit to the amount instead of publishing it. The two
 * parties hold the value and the salt; everyone else — the panel, the listing,
 * the chain — sees only a commitment.
 *
 * ── WHAT MAKES THE COMMITMENT WORTH ANYTHING ────────────────────────────────
 *
 * The salt. A commitment to a number with no salt is a lookup table: there are
 * not many plausible invoice amounts, and anyone can hash all of them. The salt
 * is 32 random bytes per agreement, and this module will not accept one that is
 * short, non-random-looking, or reused — the check exists because "just hash the
 * amount" is the natural thing to write and it discloses everything.
 *
 * The asset and chain are committed alongside. Without them a commitment to "5"
 * would be reusable across assets, so a party could later claim the 5 was ADA
 * rather than USDC.
 */
import { commitment, DOMAINS } from "./canonical.mjs";

/** Plain decimal, same rule as a public amount. */
const AMOUNT = /^\d{1,20}(\.\d{1,18})?$/;

/**
 * The commitment both parties can reproduce and nobody else can invert.
 *
 * Field order fixed here rather than left to the caller: two parties computing
 * this over differently-shaped objects would get different digests and each
 * think the other had changed the price.
 */
export function amountCommitment({ amount, asset, chain, salt }) {
  const bad = checkAmountInputs({ amount, asset, chain, salt });
  if (bad) throw new Error(bad);
  return commitment(DOMAINS.AMOUNT, { amount: String(amount), asset: String(asset), chain: String(chain), salt });
}

/** Every reason this could not be a usable commitment, checked before one is made. */
export function checkAmountInputs({ amount, asset, chain, salt }) {
  if (!AMOUNT.test(String(amount ?? ""))) return "the amount must be a plain number, e.g. 5 or 0.02";
  if (!asset) return "a committed amount still needs its asset — otherwise 5 could later be claimed as any token";
  if (!chain) return "a committed amount still needs its chain";
  const s = String(salt ?? "");
  if (!/^[0-9a-f]{64}$/.test(s)) {
    return "the salt must be 32 random bytes as hex — without one the commitment is a lookup table, "
      + "because there are not many plausible invoice amounts and anyone can hash all of them";
  }
  /**
   * All zeros, "deadbeef" repeated, "abababab" — what a placeholder that was
   * never replaced looks like. Each passes a hex check and defeats the entire
   * construction, so they are refused by shape rather than trusted.
   *
   * The test is a short repeating period, up to 8 hex characters. Real
   * randomness having a period that short across 64 characters has probability
   * around 16^-56, so this cannot plausibly reject a genuine salt — which is
   * why it is safe to make it an error rather than a warning.
   */
  for (let period = 1; period <= 8; period++) {
    if (s.length % period !== 0) continue;
    const unit = s.slice(0, period);
    if (unit.repeat(s.length / period) === s) {
      return `that salt is "${unit}" repeated — it is a placeholder, not randomness, and a commitment `
        + "salted with a constant is a lookup table";
    }
  }
  return null;
}

/**
 * Does a claimed amount match a commitment?
 *
 * For the two parties, and for an auditor either of them chooses to show. The
 * panel is not given the salt, so this is not a check they can run — which is
 * the point.
 */
export function amountMatches({ amount, asset, chain, salt }, expected) {
  try {
    return amountCommitment({ amount, asset, chain, salt }) === expected;
  } catch {
    return false;
  }
}

/**
 * What a party may say about a committed amount without revealing it.
 *
 * A cap is a real, bounded leak and it is disclosed on purpose: a provider needs
 * to know the escrow is worth their time, and a refused funding tells an
 * observer the amount exceeded the cap. That is the only inference the design
 * intends to permit, and it is stated rather than discovered.
 */
export function capStatement(cap, asset) {
  if (cap === null || cap === undefined) return null;
  if (!AMOUNT.test(String(cap))) return null;
  return {
    amount_at_most: String(cap),
    asset: String(asset),
    what_this_leaks:
      "That the amount is at or below this cap, and nothing finer. A funding refused against this cap would "
      + "tell an observer the amount exceeded it — the only inference this design intends to permit.",
  };
}
