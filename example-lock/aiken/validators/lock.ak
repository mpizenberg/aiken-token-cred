use aiken/collection/list
use aiken/crypto.{ScriptHash}
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction, Withdraw}

pub type WithdrawalIndex =
  Int

/// Lock validator, storing in its datum
/// the policy ID of the badge required to spend the UTxO.
validator lock(check_badge_validator: ScriptHash) {
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
    expect cred == Script(check_badge_validator)
    expect token_creds: Pairs<PolicyId, Data> = withdraw_redeemer_data
    list.any(token_creds, fn(Pair(id, _)) { id == owner })
  }

  else(_ctx: Data) {
    False
  }
}
