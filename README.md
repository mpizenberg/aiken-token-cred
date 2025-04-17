# Cardano Badges

This repository provides an approach to use unique Cardano native tokens as credentials.
We refer to these tokens as "badges".

The goal is to ease ownership transitions, and multisig rotations.
Instead of directly linking an onchain resource to a public key hash or a native multisig address, delegate the ownership to whoever holds the token.

Remark: only the token policy ID is verified in this approach, so fungible tokens or NFT collections sharing the same policy ID should not be used as badges.

## Building

```sh
aiken build
```

The main validator is `check_badges.ak` inside the `aiken-badges/` directory.
Other validators are provided for convenience and for examples.

## Usage

Using badges as credentials is as easy as triggering a withdrawal for the check_badges validator.
For the badges to be valid, there are the following requirements:
- The policy ID of each badge to be verified must be present in the validator redeemer.
- The badge (the token) must be spent or referenced in the Tx input at the index specified in the redeemer.
- The payment credential for the UTxO containing that token must be proven:
  - Either that UTxO is spent, or if it is referenced, the following must be true:
  - If it is a wallet address, the public key hash must be present in the `required_signers` field of the transaction.
  - If it is a script address, a withdraw purpose for that script must be present in the transaction.

## Optimizations

Further optimizations with more indexes are possible.
To keep it simple, this first iteration of the validator only requires the index of the input containing the token.

## Examples

Example usage of badges is provided in the `example-lock/` directory.
That examples shows how to use a badge to lock and unlock UTxOs.
The example contains both onchain (Aiken) and offchain code.
