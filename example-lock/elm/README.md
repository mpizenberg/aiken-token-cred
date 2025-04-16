This little elm project showcases how to use the token-cred contract to check token credentials in a lock script.

Anyone or any script holding the token can unlock the funds.

This example proceeds with these few steps:

0. (Needed only once per network) Register the token-cred script.
1. Mint a unique token, parameterized by some wallet UTxO being spent.
2. Send 2 ada to a lock script address, using the token-cred contract to check ownership.
3. Retrieve the 2 ada by presenting the token with our payment key.
4. Burn the unique token key.

You could replace steps (2) and (3) with a variant using a script address.
In that case, instead of adding our pub key to the Tx required signers field, we would have to prove we can make a withdrawal (of 0 ada) for that script address.

## Compiling this aiken + elm-cardano project

```sh
# Build the aiken code from the root of the project
aiken build

# Copy the generated blueprints to this directory
cp aiken-badges/plutus.json example-lock/elm/badges-plutus.json
cp example-lock/aiken/plutus.json example-lock/elm/lock-plutus.json

# Compile the elm code and start a local server with hot reload
cd example-lock/elm
npm install
npm run make && npm run watch
```
