use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction, Withdraw}

const token_cred_script =
  Script(#"94c48e8037705486cdb9d972464a194c92088339df749a3d2300d783")

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
    expect Some(Pair(Withdraw(cred), withdraw_redeemer_data)) =
      list.at(tx.redeemers, redeemer)
    expect cred == token_cred_script
    expect token_creds: Pairs<PolicyId, Int> = withdraw_redeemer_data
    list.any(token_creds, fn(Pair(id, _)) { id == owner })
  }

  else(_ctx: Data) {
    False
  }
}
