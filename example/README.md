This little elm-cardano project showcases how to use the token-cred contract to check token credentials in a lock script.

Anyone or any script holding the token can unlock the funds.

This example proceeds with these few steps:

0. (Needed only once per network) Register the token-cred script.
1. Mint a unique token, parameterized by some wallet UTxO being spent.
2. Send 2 ada to a lock script address, using the token-cred contract to check ownership.
3. Retrieve the 2 ada by presenting the token with our payment key.
4. Burn the unique token key.

You could replace steps (2) and (3) with a variant using a script address.
In that case, instead adding our pub key to the Tx required signers field, we would have to prove we can make a withdrawal (of 0 ada) for that script address.

> PS: this example hardcodes the script bytes of the token-cred contract from the parent directory.

## Compiling this aiken + elm-cardano project

```sh
cd lock/ && aiken build && cd ..
npx elm-cardano make src/Main.elm --output main.js && python -m http.server
```
