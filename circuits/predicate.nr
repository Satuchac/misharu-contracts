// Misharu — a predicate over a private measurement, in Noir.
//
// The Compact twin of this circuit is
// contracts/midnight/escrow/src/judge_predicates.compact. Both must satisfy
// circuits/vectors/predicate-vectors.json, which is the only thing keeping them
// from drifting: there is no Compact-to-Noir bridge, so the logic is written
// twice, and two implementations of one rule diverging silently is far more
// likely than any cryptographic break. The proof still verifies — it just
// proves something slightly different from what the other chain proved.
//
// WHY THE COMMITMENT IS NOT OPTIONAL.
//
// A circuit of the shape `main(value, threshold) -> pub bool` is VACUOUS. The
// prover chooses `value`, so a `true` output proves only that the prover can
// pick a number. The private value has to be bound to a commitment the verifier
// already trusts from somewhere else — published on chain before the proof, in
// our case — and the circuit must check that binding.
//
// That is the same reason `judge_predicates.compact` separates commitValue()
// from proveClaim(), and the same bug that made its first draft worthless: the
// commitment hashed a constant instead of the value, so the check passed for any
// number at all.
//
// WHAT IS PUBLIC: the operation, the threshold, the commitment, and the result.
// WHAT IS NOT: the measurement, and the salt.

mod vectors;

mod ops {
    pub global GTE: u8 = 0;
    pub global LTE: u8 = 1;
    pub global EQ: u8 = 2;
    pub global NEQ: u8 = 3;
}

fn main(
    value: u64,          // private: the measurement. Never leaves the prover.
    salt: Field,         // private: blinds the commitment against a dictionary attack.
    commitment: pub Field,
    op: pub u8,
    threshold: pub u64,
) -> pub bool {
    // The value proved must be the value committed.
    let c = poseidon::poseidon2::Poseidon2::hash([value as Field, salt], 2);
    assert(c == commitment, "the value proved is not the value committed");

    // A closed set of comparisons. An unrecognised op must not silently
    // evaluate to false — that would let a caller obtain a `false` for a
    // predicate nobody defined, and read it as a failed claim.
    assert(
        (op == ops::GTE) | (op == ops::LTE) | (op == ops::EQ) | (op == ops::NEQ),
        "unrecognised operation",
    );

    // Comparisons are on u64, not Field. Field arithmetic wraps modulo the
    // prime, so `>=` on a Field does not mean what a reader assumes and would
    // disagree with the Compact twin at the top of the range.
    let holds = if op == ops::GTE {
        value >= threshold
    } else if op == ops::LTE {
        value <= threshold
    } else if op == ops::EQ {
        value == threshold
    } else {
        value != threshold
    };

    holds
}

#[test]
fn gte_above() {
    let salt = 7;
    let c = poseidon::poseidon2::Poseidon2::hash([87 as Field, salt], 2);
    assert(main(87, salt, c, ops::GTE, 80) == true);
}

#[test]
fn gte_equal_is_satisfied() {
    let salt = 7;
    let c = poseidon::poseidon2::Poseidon2::hash([80 as Field, salt], 2);
    assert(main(80, salt, c, ops::GTE, 80) == true);
}

#[test]
fn gte_below_is_not() {
    let salt = 7;
    let c = poseidon::poseidon2::Poseidon2::hash([79 as Field, salt], 2);
    assert(main(79, salt, c, ops::GTE, 80) == false);
}

#[test]
fn u64_upper_bound() {
    // Where a Field-based comparison would silently disagree with Compact.
    let salt = 7;
    let v: u64 = 18446744073709551615;
    let c = poseidon::poseidon2::Poseidon2::hash([v as Field, salt], 2);
    assert(main(v, salt, c, ops::LTE, v) == true);
}

#[test(should_fail_with = "the value proved is not the value committed")]
fn a_different_value_is_refused() {
    // The assertion the whole circuit rests on: commit 40, try to prove 95.
    let salt = 7;
    let c = poseidon::poseidon2::Poseidon2::hash([40 as Field, salt], 2);
    let _ = main(95, salt, c, ops::GTE, 80);
}

#[test(should_fail_with = "unrecognised operation")]
fn an_unknown_op_is_refused() {
    let salt = 7;
    let c = poseidon::poseidon2::Poseidon2::hash([87 as Field, salt], 2);
    let _ = main(87, salt, c, 9, 80);
}

#[test]
fn print_commitment_for_prover_toml() {
    // A helper for generating Prover.toml: the commitment must be computed by
    // the SAME hash the circuit checks, or the binding assertion fails and the
    // failure looks like a circuit bug rather than a wrong input.
    let c = poseidon::poseidon2::Poseidon2::hash([87 as Field, 7], 2);
    println(c);
}
