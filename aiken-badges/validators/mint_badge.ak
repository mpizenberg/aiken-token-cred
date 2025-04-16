use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}

/// Example validator that can be used to mint badges with unique policy IDs,
/// thanks to enforcing the spending of a specific UTxO when minting.
/// But really, any token with a unique policy ID can be used as a badge.
validator mint_badge(utxo: OutputReference) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    // Retrieve the amount minted or burned
    let minted = assets.tokens(tx.mint, policy_id)
    expect [amount] = dict.values(minted)

    or {
      // Allow burning
      amount < 0,
      // Allow minting only if the utxo param is spent
      amount == 1 && list.any(
        tx.inputs,
        fn(input) { input.output_reference == utxo },
      ),
    }
  }

  else(_) {
    fail
  }
}
