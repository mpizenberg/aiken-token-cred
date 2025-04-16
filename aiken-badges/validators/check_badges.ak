use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/certificate.{Certificate, RegisterCredential}
use cardano/transaction.{Input, Transaction}

pub type Index {
  RefInputIndex(Int)
  SpentInputIndex(Int)
}

validator check_badges {
  /// Check all token credentials provided in the redeemer.
  /// For each token policy ID, also provide the index of the UTxO
  /// in the (reference) inputs containing the token (for perf optimization).
  withdraw(redeemer: Pairs<PolicyId, Index>, _account: Data, tx: Transaction) {
    let ref_inputs = tx.reference_inputs
    let inputs = tx.inputs
    let signatories = tx.extra_signatories
    let withdrawals = tx.withdrawals
    let Pair(policy_id, index) <- list.all(redeemer)
    when index is {
      RefInputIndex(idx) -> {
        // Extract reference input at provided index
        expect Some(input) = list.at(ref_inputs, idx)
        // Check the token
        check(policy_id, input, signatories, withdrawals)
      }
      SpentInputIndex(idx) -> {
        // Check presence of the token in the input at provided index
        expect Some(Input { output, .. }) = list.at(inputs, idx)
        list.has(assets.policies(output.value), policy_id)
      }
    }
  }

  /// Allow registration of the script, to enable withdrawals.
  /// TODO: enable lawful unregistrations.
  publish(_redeemer: Data, certificate: Certificate, _tx: Data) {
    when certificate is {
      RegisterCredential { .. } -> True
      _ -> False
    }
  }

  else(_ctx: Data) {
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
    Script(_) -> {
      let Pair(cred, _) <- list.any(withdrawals)
      cred == payment_cred
    }
  }
}
