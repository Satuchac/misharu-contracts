// Misharu — prove an item is in the committed evidence, without saying which.
//
// The TypeScript twin is packages/receipt/src/disclosure.ts. Both answer to
// circuits/vectors/merkle-vectors.json, and the tests below are generated from
// that file by scripts/gen-noir-merkle-tests.mjs — never transcribed, because a
// hand-copied vector tests only the transcription.
//
// WHAT THIS ADDS OVER THE PLAIN DISCLOSURE PACKAGE.
//
// `verifyDisclosure` proves "this item is in the tree" with the item and its
// position both public. That is the right shape for an auditor who was handed a
// specific document and wants to know it is genuine.
//
// This proves "I hold an item in the committed tree" with the item AND ITS INDEX
// private. The verifier learns the holder has some committed item and nothing
// about which. That matters when the position is itself the disclosure: showing
// you can prove invoice line 3 tells a counterparty the invoice has at least
// three lines and which one is in dispute.
//
// WHY SHA-256 AND NOT POSEIDON.
//
// Poseidon is far cheaper in-circuit and is the obvious choice for a new tree.
// It is the wrong choice here: our receipts already commit SHA-256 roots, so a
// Poseidon circuit would prove membership of a DIFFERENT tree than the one
// published. A cheap proof about the wrong commitment is worth nothing.
//
// WHAT THE FIXED DEPTH REALLY CONSTRAINS.
//
// A circuit's array lengths are compile-time, so one instance verifies paths of
// exactly one length. That is NOT the same as "balanced trees only", which is
// what I assumed before checking: our scheme promotes an odd node unchanged, and
// a promoted level contributes no sibling, so an odd tree simply yields shorter
// proofs for some members. The generic below is exercised at every depth the
// corpus produces, odd trees included. `main` fixes D = 3 for deployment; a tree
// of another shape needs its own instance, and that is a deployment fact rather
// than a limit on the scheme.

/**
 * Walk a path to a root.
 *
 * `is_right[i]` says whether the CURRENT node is the right child at level i —
 * i.e. the sibling sits on the left.
 */
pub fn merkle_root<let D: u32>(
    leaf: [u8; 32],
    path: [[u8; 32]; D],
    is_right: [bool; D],
) -> [u8; 32] {
    let mut current = leaf;

    for i in 0..D {
        // sha256(0x01 || left || right) — the node hash from packages/crypto.
        // The 0x01 prefix is what stops a 64-byte leaf from being replayed as an
        // interior node; it is domain separation, not decoration.
        let mut buf: [u8; 65] = [0; 65];
        buf[0] = 1;

        let sibling = path[i];
        for j in 0..32 {
            // Selection, not branching. An `if` that changed which bytes were
            // hashed would still be sound, but the position it depends on is the
            // thing this circuit exists to hide, so it is kept out of control
            // flow entirely.
            let c = current[j];
            let s = sibling[j];
            buf[1 + j] = if is_right[i] { s } else { c };
            buf[33 + j] = if is_right[i] { c } else { s };
        }
        current = sha256::sha256_var(buf, 65);
    }

    current
}

/**
 * The deployable instance: depth 3, over an item's own bytes.
 *
 * ── WHY THE CONTENT, AND NOT THE LEAF ───────────────────────────────────────
 *
 * The first version of this took `leaf: [u8; 32]` directly. That is unsound for
 * the thing it claims, and the real disclosure packages in this repository
 * prove it rather than suggest it.
 *
 * A Merkle proof necessarily hands its recipient the sibling hashes along the
 * path — and at level 0 a sibling IS the neighbouring item's leaf. In the NDA
 * case (`midnight-nda-bound-deliverable-321b0f`) two of four items were
 * disclosed and two withheld, and the two disclosed proofs between them hand
 * over the leaves of BOTH withheld items. Their level-1 siblings come in the
 * same package. So the recipient holds a complete, valid witness — leaf, path,
 * sides — for items they were deliberately never shown.
 *
 * Against a leaf-opaque circuit that witness verifies. "I hold an item in this
 * tree" would then be a claim anyone handed a disclosure could make about the
 * parts of it they were refused. `disclosure-forgery.test.ts` assembles exactly
 * that attack from the real package shape.
 *
 * Hashing the content in-circuit closes it: to satisfy this you must know the
 * bytes, and recovering them from a leaf is a SHA-256 preimage search. Knowing
 * the hash is no longer knowing the item.
 *
 * ── THE LENGTH BOUND ────────────────────────────────────────────────────────
 *
 * Array lengths are compile-time, so the content has a maximum. 256 bytes: the
 * four real disclosed items in this repository canonicalise to 109, 119, 152
 * and 158 bytes, so it fits them with room and is small enough that the extra
 * SHA-256 is not the dominant cost. An item over the bound cannot be proven by
 * this instance — a deployment limit, stated, not a silent truncation. The
 * assertion below is what makes it stated: without it a longer item would be
 * quietly hashed short and produce a leaf that is in no tree.
 */
global MAX_CONTENT: u32 = 256;

/**
 * Depth 2 — a four-item evidence bundle.
 *
 * Chosen to match real data rather than a round number. The shielded cases in
 * `deployments/cases/` carry bundles of 1, 1, 4 and 5 items; the four-item NDA
 * case is the one this instance can prove today, and the proof below is built
 * from that case's actual disclosure package rather than a fixture shaped like
 * one. A tree of another depth needs its own instance — array lengths are
 * compile-time — and that is a deployment fact, not a limit on the scheme.
 */
global DEPTH: u32 = 2;

fn main(
    content: [u8; MAX_CONTENT], // private: the item's canonical bytes, zero-padded
    content_len: u32,           // private: how many of them are real
    path: [[u8; 32]; DEPTH],    // private
    is_right: [bool; DEPTH],    // private
    root: pub [u8; 32],         // public: what the receipt published
) {
    assert(content_len <= MAX_CONTENT, "this item is longer than the circuit's bound");
    assert(content_len != 0, "an empty item is not evidence");

    // sha256(0x00 || content) — the leaf hash from packages/crypto.
    //
    // The 0x00 prefix is the same domain separation the node hash uses with
    // 0x01, and it is what stops a 64-byte item from being replayed as an
    // interior node. Dropping it here would reintroduce the very confusion the
    // scheme separates.
    let mut buf: [u8; MAX_CONTENT + 1] = [0; MAX_CONTENT + 1];
    buf[0] = 0;
    for i in 0..MAX_CONTENT {
        buf[i + 1] = content[i];
    }
    let leaf = sha256::sha256_var(buf, content_len + 1);

    assert(merkle_root(leaf, path, is_right) == root, "the item is not in the committed evidence");
}

mod corpus;
mod binding;
