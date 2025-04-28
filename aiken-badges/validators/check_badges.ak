use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/certificate.{Certificate, RegisterCredential}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{Input, Transaction}

pub type Index {
  RefInputIndex(Int)
  SpentInputIndex(Int)
}

// Benches:
// - scaling of spent badges
// - scaling of ref badges with public keys
// - scaling of ref badges with native multisigs
// - scaling of ref badges with plutus scripts

validator check_badges {
  /// Check all token credentials provided in the redeemer.
  /// For each token policy ID, also provide the index of the UTxO
  /// in the (reference) inputs containing the token (for perf optimization).
  withdraw(redeemer: Pairs<PolicyId, Index>, _account: Data, tx: Transaction) {
    let Pair(policy_id, index) <- list.all(redeemer)
    when index is {
      RefInputIndex(idx) -> {
        // Extract reference input at provided index
        expect Some(input) = list.at(tx.reference_inputs, idx)
        // Check the token
        check(policy_id, input, tx.extra_signatories, tx.withdrawals)
      }
      SpentInputIndex(idx) -> {
        // Check presence of the token in the input at provided index
        expect Some(Input { output, .. }) = list.at(tx.inputs, idx)
        list.has(assets.policies(output.value), policy_id)
      }
    }
  }

  /// Allow registration of the script, to enable withdrawals.
  /// TODO: enable lawful unregistrations.
  publish(_redeemer: Data, certificate: Certificate, _tx: Transaction) {
    when certificate is {
      RegisterCredential { .. } -> True
      _ -> False
    }
  }

  else(_ctx: ScriptContext) {
    False
  }
}

/// Check that a proof of ownership is provided for the token with that policy ID.
fn check(
  policy_id: PolicyId,
  input: Input,
  signatories: List<VerificationKeyHash>,
  withdrawals: Pairs<Credential, Lovelace>,
) -> Bool {
  // Extract the output from the input
  let Input { output, .. } = input

  // Check that the input contains the token
  expect list.has(assets.policies(output.value), policy_id)

  // Extract the payment credential of the input holding the token
  let payment_cred = output.address.payment_credential

  // Check that the payment credential is authorized
  // TODO: a perf improvement could provide the index of the cred we are looking for.
  when payment_cred is {
    VerificationKey(key_hash) -> list.has(signatories, key_hash)
    Script(_) -> pairs.has_key(withdrawals, payment_cred)
  }
}
