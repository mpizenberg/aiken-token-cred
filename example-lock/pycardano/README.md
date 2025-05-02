Currently blocked because of inability to get the Tx ID of the submitted Tx.
The kupmios provider does not return the Tx ID on submission.
And the `tx.id` property on the `Transaction.from_cbor(signed_tx)` is incorrect.
See https://github.com/Python-Cardano/pycardano/issues/443

TEMPORARY SOLUTION: using pure-python version of cbor2
I’ve updated the lock file by re-installing cbor2 with this after uv sync:

```sh
CBOR2_BUILD_C_EXTENSION=0 uv pip install --no-binary cbor2 --force-reinstall cbor2
```

So now the `uv.lock` file knows that cbor2 needs to be installed for source.
And if you want to make sure it’s not build on your machine (because then it will be cached!)
then don’t forget the `CBOR2_BUILD_C_EXTENSION=0`.

```sh
CBOR2_BUILD_C_EXTENSION=0 uv sync
```
