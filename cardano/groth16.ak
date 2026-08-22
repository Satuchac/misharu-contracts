//// Groth16 BLS12-381 verification, on Cardano.
////
//// ── WHY THIS IS AIKEN AND NOT A DEPENDENCY ──────────────────────────────────
////
//// bloxbean/zeroj demonstrates this path works on Plutus V3, and reviewing it
//// is what prompted this. Adopting it would have meant Java 25, Gradle and the
//// Julc compiler at `0.1.0-pre16` — a pre-release of a 0.1.0 — for one rail we
//// already write in Aiken, from a repository with no LICENSE file.
////
//// Everything Groth16 needs is in Aiken's stdlib: `miller_loop`,
//// `final_exponentiation`, G1/G2 decompression, scalar multiplication. So the
//// on-chain half needs no new toolchain at all.
////
//// ── WHAT THE EQUATION IS ────────────────────────────────────────────────────
////
////   e(A, B) == e(alpha, beta) · e(vk_x, gamma) · e(C, delta)
////
//// where `vk_x = IC[0] + Σ inputᵢ · IC[i+1]`. The public inputs enter the
//// equation ONLY through `vk_x`, which is why a verifier that mishandles them
//// accepts a valid proof for a statement nobody made.
////
//// ── THE TRUSTED SETUP THIS INHERITS ─────────────────────────────────────────
////
//// Groth16 needs a circuit-specific ceremony. Whoever holds its toxic waste can
//// forge proofs for that circuit forever, and no amount of on-chain checking
//// detects it. Our EVM ZK deliberately uses UltraHonk to avoid owning one
//// (docs/ZK.md §10). Anything built on this verifier inherits that obligation,
//// and it is a real cost rather than a footnote.

use aiken/builtin
use aiken/crypto/bls12_381/g1
use aiken/crypto/bls12_381/scalar

pub type VerificationKey {
  alpha: G1Element,
  beta: G2Element,
  gamma: G2Element,
  delta: G2Element,
  /// One point per public input, plus one. `IC[0]` is the constant term.
  ic: List<G1Element>,
}

pub type Proof {
  a: G1Element,
  b: G2Element,
  c: G1Element,
}

/// Compute `IC[0] + Σ inputᵢ · IC[i+1]`, or `None` if the counts disagree.
///
/// The count check is load-bearing and easy to leave out. With fewer inputs
/// than IC points the trailing points silently contribute nothing, so a proof
/// about a longer statement would verify against a shorter one — the caller
/// choosing which parts of the statement to assert.
fn accumulate(ic: List<G1Element>, inputs: List<Int>) -> Option<G1Element> {
  when ic is {
    [] -> None
    [head, ..rest] -> fold_inputs(rest, inputs, head)
  }
}

fn fold_inputs(
  ic: List<G1Element>,
  inputs: List<Int>,
  acc: G1Element,
) -> Option<G1Element> {
  when (ic, inputs) is {
    ([], []) -> Some(acc)
    ([point, ..ic_rest], [value, ..input_rest]) ->
      fold_inputs(
        ic_rest,
        input_rest,
        g1.add(acc, g1.scale(point, scalar.from_int(value))),
      )
    // Exactly one IC point per input, plus the constant term. Anything else is
    // a mismatch between the key and the statement, and must not verify.
    _ -> None
  }
}

/// Verify a Groth16 proof against a verification key and public inputs.
///
/// Returns `False` rather than failing when the shapes disagree, so a caller
/// cannot tell a malformed key from a bad proof by observing which way it
/// aborted — and so a validator using this always takes the same branch.
pub fn verify(vk: VerificationKey, proof: Proof, inputs: List<Int>) -> Bool {
  when accumulate(vk.ic, inputs) is {
    None -> False
    Some(vk_x) -> {
      // e(A, B) on one side; the three fixed pairings on the other.
      let left = builtin.bls12_381_miller_loop(proof.a, proof.b)
      let right =
        builtin.bls12_381_mul_miller_loop_result(
          builtin.bls12_381_mul_miller_loop_result(
            builtin.bls12_381_miller_loop(vk.alpha, vk.beta),
            builtin.bls12_381_miller_loop(vk_x, vk.gamma),
          ),
          builtin.bls12_381_miller_loop(proof.c, vk.delta),
        )
      builtin.bls12_381_final_verify(left, right)
    }
  }
}

/// Decompress a key from the 48/96-byte encodings snarkjs artifacts convert to.
///
/// Kept separate from `verify` so a validator can decompress once into a
/// reference script or parameter, rather than paying for it on every spend.
pub fn verification_key(
  alpha: ByteArray,
  beta: ByteArray,
  gamma: ByteArray,
  delta: ByteArray,
  ic: List<ByteArray>,
) -> VerificationKey {
  VerificationKey {
    alpha: builtin.bls12_381_g1_uncompress(alpha),
    beta: builtin.bls12_381_g2_uncompress(beta),
    gamma: builtin.bls12_381_g2_uncompress(gamma),
    delta: builtin.bls12_381_g2_uncompress(delta),
    ic: list_map_g1(ic),
  }
}

pub fn proof(a: ByteArray, b: ByteArray, c: ByteArray) -> Proof {
  Proof {
    a: builtin.bls12_381_g1_uncompress(a),
    b: builtin.bls12_381_g2_uncompress(b),
    c: builtin.bls12_381_g1_uncompress(c),
  }
}

fn list_map_g1(xs: List<ByteArray>) -> List<G1Element> {
  when xs is {
    [] -> []
    [x, ..rest] -> [builtin.bls12_381_g1_uncompress(x), ..list_map_g1(rest)]
  }
}
