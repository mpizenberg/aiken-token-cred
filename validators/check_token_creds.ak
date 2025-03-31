use aiken/collection/list
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}
use tokencred

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
    tokencred.check(policy_id, input, signatories, withdrawals)
  }

  else(_ctx: Data) {
    False
  }
}
