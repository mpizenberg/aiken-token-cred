# Lucid Evolution Frontend

This project showcases usage of [Lucid Evolution][lucid-evo] offchain code to use badges for the lock script.
Any public key or script holding the token can unlock the funds.

This example proceeds with these steps:

0. (Needed only once per network) Register the badges script.
1. Mint a badge (token with unique policy ID), parameterized by some wallet UTxO being spent.
2. Send 2 ada to a lock script address with the badge policy ID in the datum.
3. Retrieve the 2 ada by presenting the badge.
4. Burn the badge.

You could replace steps (2) and (3) with a variant using a script address instead holding the badge in a wallet.
In that case, instead of adding our pub key to the Tx required signers field, we would have to prove we can make a withdrawal (of 0 ada) for that script address.

[lucid-evo]: https://github.com/Anastasia-Labs/lucid-evolution

## Building the code

Build the aiken code and copy the blueprints in this directory:

```sh
# from the root of the repo
aiken build
cp aiken-badges/plutus.json example-lock/solid-lucid-evo/badges-plutus.json
cp example-lock/aiken/plutus.json example-lock/solid-lucid-evo/lock-plutus.json
```

Then install and build and start the dev server:

```bash
# from this directory
bun install # or npm / pnpm / yarn
bun run dev
```
