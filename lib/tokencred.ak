use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, PolicyId}
use cardano/transaction.{Input}

pub fn check(
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
