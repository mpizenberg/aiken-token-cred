use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/certificate.{Certificate, RegisterCredential, UnregisterCredential}
use cardano/transaction.{Input, Transaction}

pub type Index =
  Int

validator check_token_creds {
  /// Check all token credentials provided in the redeemer.
  /// For each token policy ID, also provide the index of the UTxO
  /// in the reference inputs containing the token (small perf optimization).
  withdraw(redeemer: Pairs<PolicyId, Index>, _account: Data, tx: Transaction) {
    let ref_inputs = tx.reference_inputs
    let signatories = tx.extra_signatories
    let withdrawals = tx.withdrawals
    let Pair(policy_id, ref_input_index) <- list.all(redeemer)
    // Extract ref input at provided index
    expect Some(input) = list.at(ref_inputs, ref_input_index)
    check(policy_id, input, signatories, withdrawals)
  }

  /// Allow (un)registration of the script, to enable withdrawals.
  publish(_redeemer: Data, certificate: Certificate, _tx: Data) {
    when certificate is {
      RegisterCredential { .. } -> True
      UnregisterCredential { .. } -> True
      _ -> False
    }
  }

  else(_ctx: Data) {
    False
  }
}

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
  when payment_cred is {
    VerificationKey(key_hash) -> list.has(signatories, key_hash)
    Script(_) -> {
      let Pair(cred, _) <- list.any(withdrawals)
      cred == payment_cred
    }
  }
}
