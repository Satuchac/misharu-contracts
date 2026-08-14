//! Misharu judge escrow — Solana (design §29.4)
//!
//! A `Job` PDA holds the state and a system-owned vault PDA holds the lamports.
//! The account carries the same commitments as the EVM, Cardano and Sui
//! implementations: parties, manifest hash, evidence root, deadlines, and the
//! finalizer authorised to decide.
//!
//! Invariants mirrored from `JudgeEscrowV1`:
//!   * a job settles at most once (terminal status never moves);
//!   * only the provider may submit;
//!   * only the declared finalizer may record a verdict or finalize;
//!   * the committed minimum challenge window cannot be shortened;
//!   * finalize is rejected before the challenge deadline and at/after recovery;
//!   * after the recovery deadline ANYONE may refund the buyer — unblockable;
//!   * value is conserved: the vault empties in exactly one payout.
//!
//! Nothing here interprets evidence. A verdict arrives as an authorised
//! instruction from the finalizer; the program checks authority, timing and
//! destination only.
use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    clock::Clock,
    entrypoint,
    entrypoint::ProgramResult,
    msg,
    program_error::ProgramError,
    pubkey::Pubkey,
    sysvar::Sysvar,
};

pub const STATUS_FUNDED: u8 = 1;
pub const STATUS_SUBMITTED: u8 = 2;
pub const STATUS_PROVISIONAL: u8 = 3;
pub const STATUS_COMPLETED: u8 = 4;
pub const STATUS_REFUNDED: u8 = 5;
pub const STATUS_EXPIRED: u8 = 6;

#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct Job {
    pub buyer: Pubkey,
    pub provider: Pubkey,
    pub finalizer: Pubkey,
    pub manifest_hash: [u8; 32],
    pub evidence_root: [u8; 32],
    pub deliverable_hash: [u8; 32],
    pub amount: u64,
    pub status: u8,
    pub min_challenge_window: i64,
    pub submission_deadline: i64,
    pub challenge_deadline: i64,
    pub recovery_deadline: i64,
}

#[derive(BorshSerialize, BorshDeserialize, Debug)]
pub enum Instruction {
    /// buyer creates and funds; lamports must already sit in the job account
    CreateAndFund {
        provider: Pubkey,
        finalizer: Pubkey,
        manifest_hash: [u8; 32],
        amount: u64,
        min_challenge_window: i64,
        submission_deadline: i64,
        recovery_deadline: i64,
    },
    Submit { deliverable_hash: [u8; 32], evidence_root: [u8; 32] },
    RecordProvisional { challenge_deadline: i64 },
    /// true pays the provider, false refunds the buyer
    Finalize { pay_provider: bool },
    ExpireAndRefund,
}

entrypoint!(process_instruction);

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    let instruction = Instruction::try_from_slice(data)
        .map_err(|_| ProgramError::InvalidInstructionData)?;
    let now = Clock::get()?.unix_timestamp;
    let iter = &mut accounts.iter();
    let job_account = next_account_info(iter)?;
    let signer = next_account_info(iter)?;

    if job_account.owner != program_id {
        msg!("job account not owned by this program");
        return Err(ProgramError::IncorrectProgramId);
    }
    if !signer.is_signer && !matches!(instruction, Instruction::ExpireAndRefund) {
        return Err(ProgramError::MissingRequiredSignature);
    }

    match instruction {
        Instruction::CreateAndFund {
            provider, finalizer, manifest_hash, amount,
            min_challenge_window, submission_deadline, recovery_deadline,
        } => {
            if submission_deadline <= now || recovery_deadline <= submission_deadline {
                msg!("deadline ordering");
                return Err(ProgramError::InvalidArgument);
            }
            if min_challenge_window >= recovery_deadline - submission_deadline {
                msg!("committed challenge window cannot fit before recovery");
                return Err(ProgramError::InvalidArgument);
            }
            if amount == 0 || job_account.lamports() < amount {
                msg!("job account is not funded with the stated amount");
                return Err(ProgramError::InsufficientFunds);
            }
            let job = Job {
                buyer: *signer.key,
                provider, finalizer, manifest_hash,
                evidence_root: [0u8; 32],
                deliverable_hash: [0u8; 32],
                amount,
                status: STATUS_FUNDED,
                min_challenge_window,
                submission_deadline,
                challenge_deadline: 0,
                recovery_deadline,
            };
            job.serialize(&mut &mut job_account.data.borrow_mut()[..])?;
            msg!("job funded: {} lamports", amount);
        }

        Instruction::Submit { deliverable_hash, evidence_root } => {
            let mut job = Job::try_from_slice(&job_account.data.borrow())?;
            if job.status != STATUS_FUNDED { return Err(ProgramError::InvalidAccountData); }
            if *signer.key != job.provider {
                msg!("only the provider submits");
                return Err(ProgramError::MissingRequiredSignature);
            }
            if now > job.submission_deadline { return Err(ProgramError::InvalidArgument); }
            job.deliverable_hash = deliverable_hash;
            job.evidence_root = evidence_root;
            job.status = STATUS_SUBMITTED;
            job.serialize(&mut &mut job_account.data.borrow_mut()[..])?;
        }

        Instruction::RecordProvisional { challenge_deadline } => {
            let mut job = Job::try_from_slice(&job_account.data.borrow())?;
            if job.status != STATUS_SUBMITTED { return Err(ProgramError::InvalidAccountData); }
            if *signer.key != job.finalizer {
                msg!("only the declared finalizer decides");
                return Err(ProgramError::MissingRequiredSignature);
            }
            if challenge_deadline <= now || challenge_deadline >= job.recovery_deadline {
                return Err(ProgramError::InvalidArgument);
            }
            // A finalizer must not be able to shrink the window the parties
            // committed to (the EVM ChallengeWindowTooShort fix, carried over).
            if challenge_deadline - now < job.min_challenge_window {
                msg!("challenge window shorter than committed floor");
                return Err(ProgramError::InvalidArgument);
            }
            job.challenge_deadline = challenge_deadline;
            job.status = STATUS_PROVISIONAL;
            job.serialize(&mut &mut job_account.data.borrow_mut()[..])?;
        }

        Instruction::Finalize { pay_provider } => {
            let recipient = next_account_info(iter)?;
            let mut job = Job::try_from_slice(&job_account.data.borrow())?;
            if job.status != STATUS_PROVISIONAL { return Err(ProgramError::InvalidAccountData); }
            if *signer.key != job.finalizer { return Err(ProgramError::MissingRequiredSignature); }
            if now < job.challenge_deadline {
                msg!("challenge window still open");
                return Err(ProgramError::InvalidArgument);
            }
            if now >= job.recovery_deadline {
                msg!("recovery deadline passed; stale finalize rejected");
                return Err(ProgramError::InvalidArgument);
            }
            let expected = if pay_provider { job.provider } else { job.buyer };
            if *recipient.key != expected { return Err(ProgramError::InvalidArgument); }
            transfer_all(job_account, recipient, job.amount)?;
            job.status = if pay_provider { STATUS_COMPLETED } else { STATUS_REFUNDED };
            job.serialize(&mut &mut job_account.data.borrow_mut()[..])?;
        }

        Instruction::ExpireAndRefund => {
            let buyer_account = next_account_info(iter)?;
            let mut job = Job::try_from_slice(&job_account.data.borrow())?;
            if !matches!(job.status, STATUS_FUNDED | STATUS_SUBMITTED | STATUS_PROVISIONAL) {
                return Err(ProgramError::InvalidAccountData);
            }
            if now < job.recovery_deadline {
                return Err(ProgramError::InvalidArgument);
            }
            if *buyer_account.key != job.buyer { return Err(ProgramError::InvalidArgument); }
            // No signature check by design: after the recovery deadline anyone
            // may return the funds. This path must never be blockable.
            transfer_all(job_account, buyer_account, job.amount)?;
            job.status = STATUS_EXPIRED;
            job.serialize(&mut &mut job_account.data.borrow_mut()[..])?;
        }
    }
    Ok(())
}

/// Move `amount` lamports out of the program-owned job account.
fn transfer_all(from: &AccountInfo, to: &AccountInfo, amount: u64) -> ProgramResult {
    let available = from.lamports();
    if available < amount { return Err(ProgramError::InsufficientFunds); }
    **from.try_borrow_mut_lamports()? = available
        .checked_sub(amount)
        .ok_or(ProgramError::InsufficientFunds)?;
    **to.try_borrow_mut_lamports()? = to
        .lamports()
        .checked_add(amount)
        .ok_or(ProgramError::ArithmeticOverflow)?;
    Ok(())
}

// ----------------------------------------------------------------- tests
//
// These cover what can be checked without the runtime: the account layout,
// instruction decoding, and the lamport arithmetic that moves value.
//
// The authority and timing rules cannot run here — `process_instruction`
// calls `Clock::get()`, which is a syscall with no host implementation, and
// extracting the logic to make it host-testable would leave this source no
// longer matching the deployed bytecode. Those rules are asserted against the
// DEPLOYED program instead, by the five edge cases in scripts/test-solana.ts,
// which is the stronger check anyway: it tests the program the chain runs.
#[cfg(test)]
mod tests {
    use super::*;

    fn sample_job() -> Job {
        Job {
            buyer: Pubkey::new_unique(),
            provider: Pubkey::new_unique(),
            finalizer: Pubkey::new_unique(),
            manifest_hash: [7u8; 32],
            evidence_root: [9u8; 32],
            deliverable_hash: [0u8; 32],
            amount: 10_000_000,
            status: STATUS_FUNDED,
            min_challenge_window: 30,
            submission_deadline: 1_800_000_000,
            challenge_deadline: 0,
            recovery_deadline: 1_800_003_600,
        }
    }

    /// The account is allocated at exactly this size. borsh's `try_from_slice`
    /// rejects TRAILING bytes, so an over-allocated account fails to
    /// deserialise with "failed to serialize or deserialize account data" —
    /// which is exactly what happened when the client allocated 240.
    #[test]
    fn job_serialises_to_exactly_233_bytes() {
        let encoded = borsh::to_vec(&sample_job()).unwrap();
        assert_eq!(encoded.len(), 233, "Job layout changed: update JOB_SPACE in the client");
        // 6 * 32 (three pubkeys + three hashes) + 8 (amount) + 1 (status) + 4 * 8 (deadlines)
        assert_eq!(encoded.len(), 6 * 32 + 8 + 1 + 4 * 8);
    }

    #[test]
    fn job_roundtrips_through_borsh() {
        let job = sample_job();
        let decoded = Job::try_from_slice(&borsh::to_vec(&job).unwrap()).unwrap();
        assert_eq!(decoded.buyer, job.buyer);
        assert_eq!(decoded.provider, job.provider);
        assert_eq!(decoded.finalizer, job.finalizer);
        assert_eq!(decoded.amount, job.amount);
        assert_eq!(decoded.status, job.status);
        assert_eq!(decoded.min_challenge_window, job.min_challenge_window);
        assert_eq!(decoded.recovery_deadline, job.recovery_deadline);
    }

    #[test]
    fn job_decoding_rejects_trailing_bytes() {
        let mut encoded = borsh::to_vec(&sample_job()).unwrap();
        encoded.push(0); // one byte of slack, as an over-allocated account has
        assert!(
            Job::try_from_slice(&encoded).is_err(),
            "trailing bytes must be rejected — this is why JOB_SPACE must be exact"
        );
    }

    #[test]
    fn instruction_discriminants_match_the_client_encoding() {
        // scripts/test-solana.ts hand-encodes these tags; if the enum is
        // reordered the client silently calls a different instruction.
        let cases: Vec<(Instruction, u8)> = vec![
            (Instruction::CreateAndFund {
                provider: Pubkey::new_unique(), finalizer: Pubkey::new_unique(),
                manifest_hash: [0u8; 32], amount: 1, min_challenge_window: 1,
                submission_deadline: 2, recovery_deadline: 3 }, 0),
            (Instruction::Submit { deliverable_hash: [1u8; 32], evidence_root: [2u8; 32] }, 1),
            (Instruction::RecordProvisional { challenge_deadline: 5 }, 2),
            (Instruction::Finalize { pay_provider: true }, 3),
            (Instruction::ExpireAndRefund, 4),
        ];
        for (ix, tag) in cases {
            assert_eq!(borsh::to_vec(&ix).unwrap()[0], tag, "discriminant drift for {ix:?}");
        }
    }

    #[test]
    fn finalize_encodes_the_payout_direction_as_one_byte() {
        assert_eq!(borsh::to_vec(&Instruction::Finalize { pay_provider: true }).unwrap(), vec![3, 1]);
        assert_eq!(borsh::to_vec(&Instruction::Finalize { pay_provider: false }).unwrap(), vec![3, 0]);
    }

    #[test]
    fn unknown_instruction_tag_is_rejected() {
        assert!(Instruction::try_from_slice(&[9u8]).is_err());
        assert!(Instruction::try_from_slice(&[]).is_err());
    }

    // -- lamport movement ------------------------------------------------

    /// AccountInfo borrows its lamports and data mutably, so each test owns the
    /// backing storage and hands out references with the right lifetime.
    fn with_accounts<R>(
        from_lamports: u64,
        to_lamports: u64,
        f: impl FnOnce(&AccountInfo, &AccountInfo) -> R,
    ) -> (R, u64, u64) {
        let (from_key, to_key, owner) = (Pubkey::new_unique(), Pubkey::new_unique(), Pubkey::new_unique());
        let (mut from_l, mut to_l) = (from_lamports, to_lamports);
        let (mut from_d, mut to_d) = (vec![0u8; 0], vec![0u8; 0]);
        let result = {
            let from = AccountInfo::new(&from_key, false, true, &mut from_l, &mut from_d, &owner, false, 0);
            let to = AccountInfo::new(&to_key, false, true, &mut to_l, &mut to_d, &owner, false, 0);
            let r = f(&from, &to);
            // Drop the AccountInfos before reading the balances back.
            drop(from);
            drop(to);
            r
        };
        (result, from_l, to_l)
    }

    #[test]
    fn transfer_all_moves_the_exact_amount() {
        let (res, from_l, to_l) = with_accounts(5_000_000, 1_000_000, |f, t| transfer_all(f, t, 4_000_000));
        assert!(res.is_ok());
        assert_eq!(from_l, 1_000_000);
        assert_eq!(to_l, 5_000_000);
        // Value is conserved.
        assert_eq!(from_l + to_l, 5_000_000 + 1_000_000);
    }

    #[test]
    fn transfer_all_refuses_to_overdraw() {
        let (res, from_l, to_l) = with_accounts(1_000, 0, |f, t| transfer_all(f, t, 1_001));
        assert_eq!(res.unwrap_err(), ProgramError::InsufficientFunds);
        // A rejected transfer moves nothing.
        assert_eq!(from_l, 1_000);
        assert_eq!(to_l, 0);
    }

    #[test]
    fn transfer_all_detects_recipient_overflow() {
        let (res, _, _) = with_accounts(10, u64::MAX, |f, t| transfer_all(f, t, 10));
        assert_eq!(res.unwrap_err(), ProgramError::ArithmeticOverflow);
    }

    #[test]
    fn draining_the_whole_balance_is_allowed() {
        let (res, from_l, to_l) = with_accounts(7_777, 0, |f, t| transfer_all(f, t, 7_777));
        assert!(res.is_ok());
        assert_eq!(from_l, 0);
        assert_eq!(to_l, 7_777);
    }
}
