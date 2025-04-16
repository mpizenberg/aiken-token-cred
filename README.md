# Cardano Badges

This repository provides an approach to use unique Cardano native tokens as credentials.

The goal is to ease ownership transitions, and multisig rotations.
Instead of directly linking an onchain resource to a public key hash or a native multisig address, delegate the ownership to whoever holds the token.

Remark: only the token policy ID is verified in this approach, so this should not be used with fungible tokens or NFT collections sharing the same policy ID.

## Building

```sh
aiken build
```

## Usage

Using token credentials is as easy as triggering a withdrawal for the script credential of this validator.
For the credentials to be valid, there are the following requirements:
- Each token policy ID to be verified must be present in the redeemer.
- The token must be present in an input (or reference input) at the index specified in the redeemer.
- The payment credential for the UTxO containing the token must be proven:
  - Either that UTxO is spent, or if it is referenced, the following must be true:
  - If it is a wallet address, the public key hash must be present in the `required_signers` field of the transaction.
  - If it is a script address, a withdraw action for that script must be present in the transaction.

## Optimizations

Further optimizations with more indexes are possible.
To keep it simple, this first iteration of the validator only requires the index of the input containing the token.
