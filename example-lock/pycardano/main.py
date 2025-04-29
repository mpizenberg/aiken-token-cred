from blockfrost import ApiUrls
from pycardano import (
    Address,
    KupoOgmiosV6ChainContext,
    MultiAsset,
    Network,
    BlockFrostChainContext,
    PlutusV3Script,
    Redeemer,
    ScriptHash,
    StakeCredential,
    StakeRegistration,
    Transaction,
    TransactionBuilder,
    TransactionOutput,
    TransactionWitnessSet,
    Value,
)
from dotenv import load_dotenv
import os
import json
from urllib.parse import urlparse


def main():
    # Load environment variables
    load_dotenv()
    blockfrost_project_id = os.environ.get("BLOCKFROST_PROJECT_ID") or ""
    ogmios_url = os.environ.get("OGMIOS_URL") or ""
    kupo_url = os.environ.get("KUPO_URL") or ""
    wallet_address_bech32 = os.environ.get("WALLET_ADDRESS") or ""

    # Use Preview
    network = Network.TESTNET

    # Retrieve the user wallet address
    wallet_address = Address.decode(wallet_address_bech32)

    # Create a BlockFrost chain context
    # context = BlockFrostChainContext(
    #     blockfrost_project_id, base_url=ApiUrls.preview.value
    # )
    parsed_url = urlparse(ogmios_url)
    scheme = parsed_url.scheme
    context = KupoOgmiosV6ChainContext(
        host=parsed_url.hostname or "",
        port=parsed_url.port or (443 if scheme == "https" else 1337),
        path=parsed_url.path,
        secure=scheme == "https" or scheme == "wss",
        kupo_url=kupo_url,
    )

    # Load the script bytes from the blueprint json files
    badges_blueprint = load_blueprint("badges-plutus.json")
    lock_blueprint = load_blueprint("lock-plutus.json")
    validators = badges_blueprint | lock_blueprint
    print("validators:", validators.keys())

    # # Register the badges validator
    # badges_validator = validators["check_badges.check_badges.withdraw"]
    # tx = register_badge_script(context, wallet_address, badges_validator["hash"])
    # print("Register Tx (unsigned):", tx.to_cbor_hex())
    # signed_tx_hex = input("Paste signed Tx cbor hex: ")
    # signed_tx = Transaction.from_cbor(signed_tx_hex)
    # tx_id = context.submit_tx_cbor(signed_tx_hex)
    # print("Tx submitted with ID:", tx_id)

    # Mint the badge
    mint_validator = validators["mint_badge.mint_badge.mint"]
    tx = mint_badge(context, wallet_address, mint_validator)
    print("Mint Tx (unsigned):", tx.to_cbor_hex())
    signed_tx_hex = input("Paste signed Tx cbor hex: ")
    signed_tx = Transaction.from_cbor(signed_tx_hex)
    tx_id = context.submit_tx_cbor(signed_tx_hex)
    print("Tx submitted with ID:", tx_id)


def load_blueprint(file_path):
    validators = {}
    with open(file_path, "r") as f:
        for v in json.load(f).get("validators", []):
            validators[v["title"]] = {
                "compiled_code": bytes.fromhex(v["compiledCode"]),
                "hash": bytes.fromhex(v["hash"]),
            }
    return validators


def register_badge_script(context, wallet_address: Address, script_hash: bytes):
    builder = TransactionBuilder(context)
    builder.add_input_address(wallet_address)

    # Add the registration certificate
    certificates = []
    certificates.append(StakeRegistration(StakeCredential(ScriptHash(script_hash))))
    builder.certificates = certificates

    # Build the tx
    tx_body = builder.build(change_address=wallet_address)
    tx = Transaction(tx_body, TransactionWitnessSet())
    return tx


def mint_badge(context, wallet_address: Address, validator):
    builder = TransactionBuilder(context)
    builder.add_input_address(wallet_address)

    # Get the first wallet UTxOs to guarantee mint unicity
    utxos = context.utxos(wallet_address)
    picked_utxo = utxos[0]
    builder.add_input(picked_utxo)

    # Apply the picked utxo to the validator
    unnapplied_script = PlutusV3Script(validator["compiled_code"])

    # Mint the token
    policy_id = validator["hash"]
    mint = MultiAsset.from_primitive({policy_id: {b"": 1}})
    builder.mint = mint

    # Mandatory creation of an output because it’s not done
    # by the builder before uplc evaluation ??? TODO: not sure, still failing
    builder.add_output(TransactionOutput(wallet_address, Value(1_500_000, mint)))

    # Add the script to the witness set
    builder.add_minting_script(script, Redeemer([]))

    # Build the tx
    tx_body = builder.build(change_address=wallet_address, auto_required_signers=False)
    tx_witness_set = builder.build_witness_set(True)
    tx = Transaction(tx_body, tx_witness_set)
    return tx


if __name__ == "__main__":
    main()
