use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction, Withdraw}

const token_cred_script =
  Script(#"3f64a17e7dcb294ede555c607ba879671155e1807d5ad8e7b556b71a")

pub type WithdrawalIndex =
  Int

validator lock {
  spend(
    datum: Option<PolicyId>,
    redeemer: WithdrawalIndex,
    _utxo: Data,
    tx: Transaction,
  ) {
    // Retrieve the (token) owner from the datum
    expect Some(owner) = datum

    // Check that the token-cred withdraw script is present,
    // with the owner policy in its redeemer.
    trace @"redeemers": tx.redeemers
    expect Some(Pair(Withdraw(cred), withdraw_redeemer_data)) =
      list.at(tx.redeemers, redeemer)
    expect cred == token_cred_script
    expect token_creds: Pairs<PolicyId, Data> = withdraw_redeemer_data
    list.any(token_creds, fn(Pair(id, _)) { id == owner })
  }

  else(_ctx: Data) {
    False
  }
}
