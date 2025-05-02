from blockfrost import ApiUrls
from pycardano.plutus import classproperty
from pycardano import (
    Address,
    KupoOgmiosV6ChainContext,
    MultiAsset,
    Network,
    BlockFrostChainContext,
    PlutusData,
    PlutusV3Script,
    RawPlutusData,
    Redeemer,
    ScriptHash,
    StakeCredential,
    StakeRegistration,
    Transaction,
    TransactionBuilder,
    TransactionInput,
    TransactionWitnessSet,
    Value,
)
from dotenv import load_dotenv
import sys
import os
import json
import tempfile
import subprocess
import readline  # Just to override the input() function with something more robust with more than 1024K chars limit
from pathlib import Path
from urllib.parse import urlparse
from dataclasses import dataclass


@dataclass
class OutputRefData(PlutusData):
    """PlutusData representation for an output reference"""

    @classproperty
    def CONSTR_ID(cls):
        return 0

    tx_id: bytes
    output_index: int

    @classmethod
    def from_ref(cls, output_ref: TransactionInput):
        return cls(output_ref.transaction_id.payload, output_ref.index)


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

    # Create a chain context (API provider)
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

    # Get the first wallet UTxOs to guarantee mint unicity
    print("Retrieving wallet UTxOs ...")
    utxos = context.utxos(wallet_address)
    picked_utxo = utxos[0]

    # Apply the parameters needed to each validator
    print("Applying parameters to each validator ...")
    validators = []
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Apply the picked utxo to the mint validator
        applied_mint_path = temp_path / "applied_mint.json"
        mint_param = OutputRefData.from_ref(picked_utxo.input)
        subprocess.run(
            [
                "/Users/piz/git/aiken-lang/aiken/target/release/aiken",
                "blueprint",
                "apply",
                "--in",
                "badges-plutus.json",
                "--out",
                applied_mint_path,
                "--module",
                "mint_badge",
                "--validator",
                "mint_badge",
                mint_param.to_cbor_hex(),
            ],
        )

        # Load the updated blueprint for badges (contains all validators)
        badges_blueprint = load_blueprint(applied_mint_path)

        # Apply the badges validator script hash to the lock validator
        badges_validator = badges_blueprint["check_badges.check_badges.withdraw"]
        badges_script_hash = badges_validator["hash"]
        hash_param = RawPlutusData.from_primitive(badges_script_hash)
        applied_lock_path = temp_path / "applied_lock.json"
        subprocess.run(
            [
                "/Users/piz/git/aiken-lang/aiken/target/release/aiken",
                "blueprint",
                "apply",
                "--in",
                "lock-plutus.json",
                "--out",
                applied_lock_path,
                "--module",
                "lock",
                "--validator",
                "lock",
                hash_param.to_cbor_hex(),
            ],
        )

        # Load the updated blueprint for the lock script
        lock_blueprint = load_blueprint(applied_lock_path)

        # Update the validators variable
        validators = badges_blueprint | lock_blueprint
        print("validators:", validators.keys())

    # Register the badges validator
    register = False
    if register:
        print("Building the registration Tx ...")
        badges_validator = validators["check_badges.check_badges.withdraw"]
        tx = register_badge_script(context, wallet_address, badges_validator["hash"])
        sign_and_submit("Register", context, tx)
        print("Terminating. You need to restart with register=False in the code.")
        sys.exit(0)

    # Mint the badge
    print("Building the mint Tx ...")
    mint_validator = validators["mint_badge.mint_badge.mint"]
    tx = mint_badge(context, wallet_address, mint_validator, picked_utxo)
    signed_tx = sign_and_submit("Mint", context, tx)
    print("Tx submitted with ID:", signed_tx.id)

    # TODO: Lock assets
    sys.exit(0)
    print("Building the lock Tx ...")
    lock_validator = validators["lock.lock.spend"]
    tx = lock_assets(context, wallet_address, lock_validator)
    signed_tx = sign_and_submit("Locking", context, tx)
    print("Tx submitted with ID:", signed_tx.id)

    # TODO: Unlock assets
    # TODO: Burn the badge


def load_blueprint(file_path):
    validators = {}
    with open(file_path, "r") as f:
        for v in json.load(f).get("validators", []):
            validators[v["title"]] = {
                "compiled_code": bytes.fromhex(v["compiledCode"]),
                "hash": bytes.fromhex(v["hash"]),
            }
    return validators


def sign_and_submit(label, context, tx) -> Transaction:
    print(f"{label} Tx (unsigned):", tx.to_cbor_hex())
    print("Paste signed Tx cbor hex: ", end="", flush=True)
    signed_tx_hex = input()
    signed_tx = Transaction.from_cbor(signed_tx_hex)
    context.submit_tx_cbor(signed_tx_hex)
    return signed_tx  # pyright: ignore


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


def mint_badge(context, wallet_address: Address, validator, picked_utxo):
    builder = TransactionBuilder(context)
    builder.add_input_address(wallet_address)

    # Get the first wallet UTxOs to guarantee mint unicity
    builder.add_input(picked_utxo)

    # Mint the token
    policy_id = validator["hash"]
    mint = MultiAsset.from_primitive({policy_id: {b"": 1}})
    builder.mint = mint

    # Add the script to the witness set
    script = PlutusV3Script(validator["compiled_code"])
    builder.add_minting_script(script, Redeemer([]))

    # Build the tx
    tx_body = builder.build(change_address=wallet_address, auto_required_signers=False)
    tx_witness_set = builder.build_witness_set(True)
    return Transaction(tx_body, tx_witness_set)


if __name__ == "__main__":
    main()
