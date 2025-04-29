import { createSignal, Show } from "solid-js";
import { cip30Discover, Cip30Wallet } from "./Wallet.ts";
import {
  Blockfrost,
  WebWallet,
  Blaze,
  Kupmios,
  Provider,
  Constr,
  Data,
  Wallet,
  applyParams,
  cborToScript,
} from "@blaze-cardano/sdk";
import {
  Address,
  PolicyId,
  Script,
  Credential,
  Transaction,
  AssetName,
  TransactionUnspentOutput,
  TransactionInput,
  NetworkId,
  CredentialType,
  Hash28ByteBase16,
  AddressType,
  Ed25519KeyHashHex,
  RewardAccount,
  Evaluator,
  hardCodedProtocolParams,
  SLOT_CONFIG_NETWORK,
} from "@blaze-cardano/core";
// import { makeUplcEvaluator } from "@blaze-cardano/vm";
import { Unwrapped } from "@blaze-cardano/ogmios";

type LoadedWallet = Cip30Wallet & {
  api: WebWallet;
  changeAddress: Address;
  utxos: TransactionUnspentOutput[] | undefined;
};

type State =
  | "Startup"
  | "WalletsDiscovered"
  | "WalletConnected"
  | "BlueprintLoaded"
  | "ParametersSet"
  | "BadgeMintingDone"
  | "LockingDone"
  | "UnlockingDone"
  | "BadgeBurningDone";

type AppContext = {
  loadedWallet: LoadedWallet;
  localStateUtxos: TransactionUnspentOutput[];
  badgesScript: {
    hash: Hash28ByteBase16;
    validator: Script;
    credential: Credential;
  };
  uniqueMint: {
    pickedUtxo: TransactionUnspentOutput;
    pickedUtxoRef: string;
    validator: Script;
    policyId: PolicyId;
  };
  lockScript: {
    address: Address;
    validator: Script;
    hash: string;
  };
};

function App() {
  const networkId: NetworkId = NetworkId.Testnet; // 0: Testnet, 1: Mainnet
  // const uplcVm: Evaluator = makeUplcEvaluator(
  //   hardCodedProtocolParams,
  //   1,
  //   1,
  //   SLOT_CONFIG_NETWORK.Preview,
  // );
  const [state, setState] = createSignal<State>("Startup");
  const [wallets, setWallets] = createSignal<Cip30Wallet[]>([]);
  const [loadedWallet, setLoadedWallet] = createSignal<LoadedWallet | null>(
    null,
  );
  const [scripts, setScripts] = createSignal<BlueprintScript[]>([]);
  const [appContext, setAppContext] = createSignal<AppContext | null>(null);
  const [badgeUtxo, setBadgeUtxo] =
    createSignal<TransactionUnspentOutput | null>(null);
  const [latestTx, setLatestTx] = createSignal<Transaction | null>(null);
  const [errors, setErrors] = createSignal("");

  // Initialize Blaze library with some API provider
  let provider: Provider | null = null;
  // const blockfrostProvider = new Blockfrost({
  //   network: "cardano-preview",
  //   projectId: import.meta.env.VITE_BLOCKFROST_PROJECT_ID,
  // });
  // provider = blockfrostProvider;
  (async function () {
    const ogmios = await Unwrapped.Ogmios.new(
      "https://ogmios1qsrks7v96368z9f7s2l.preview-v6.ogmios-m1.demeter.run",
    );
    const kupmiosProvider = new Kupmios(
      "https://kupo1wdfamtee7aksurslg0h.preview-v2.kupo-m1.demeter.run",
      ogmios,
    );
    provider = kupmiosProvider;
  })();

  // Discover installed CIP-30 wallets
  setWallets(cip30Discover());
  setState("WalletsDiscovered");

  // Blaze to be initialized after wallet is enabled
  let blaze: Blaze<Provider, Wallet> | undefined;

  type BlueprintScript = {
    name: string;
    scriptBytes: string;
    hash: string;
    hasParams: boolean;
  };

  function loadBlueprint() {
    const handleBlueprint = (result: {
      ok: boolean;
      data?: BlueprintScript[];
      error?: unknown;
    }) => {
      if (result.ok && result.data) {
        setScripts([...scripts(), ...result.data]);
        setState("BlueprintLoaded");
        setErrors("");
      } else {
        setErrors(result.error?.toString() || "Unknown error");
      }
    };

    Promise.all([
      fetch("lock-plutus.json").then((r) => r.json()),
      fetch("badges-plutus.json").then((r) => r.json()),
    ])
      .then(([lockData, badgesData]) => {
        const blueprints = [
          ...lockData.validators,
          ...badgesData.validators,
        ].map((v) => ({
          name: v.title,
          scriptBytes: v.compiledCode,
          hash: v.hash,
          hasParams: v.parameters !== undefined,
        }));
        handleBlueprint({ ok: true, data: blueprints });
      })
      .catch((err) => {
        handleBlueprint({ ok: false, error: err });
      });
  }

  async function pickUtxoParam() {
    const wallet = loadedWallet()!;
    const walletUtxos = wallet.utxos ?? [];

    if (walletUtxos.length === 0) {
      setErrors("Selected wallet has no UTxO.");
      return;
    }

    // Pick the first utxo
    const headUtxo = walletUtxos[0];

    try {
      // Find mint script in blueprint
      const mintBlueprint = scripts().find(
        (s) => s.name === "mint_badge.mint_badge.mint",
      );
      if (!mintBlueprint) throw new Error("Mint script not found in blueprint");

      const mintScriptBeforeApply = cborToScript(
        mintBlueprint.scriptBytes,
        "PlutusV3",
      );
      const appliedMint = applyParams(
        mintScriptBeforeApply.asPlutusV3()!.rawBytes(),
        // Convert headUtxo reference into Data
        Data.to(
          new Constr(0, [
            headUtxo.input().transactionId(),
            headUtxo.input().index(),
          ]),
        ),
      );
      const mintScript = cborToScript(appliedMint, "PlutusV3");

      // Find badges script in blueprint
      const badgesBlueprint = scripts().find(
        (s) => s.name === "check_badges.check_badges.withdraw",
      );
      if (!badgesBlueprint)
        throw new Error("Badges script not found in blueprint");

      const badgesScript = cborToScript(
        badgesBlueprint.scriptBytes,
        "PlutusV3",
      );
      const badgesScriptCred: Credential = Credential.fromCore({
        type: CredentialType.ScriptHash,
        hash: badgesScript.hash(),
      });

      // Find lock script in blueprint
      const lockBlueprint = scripts().find((s) => s.name === "lock.lock.spend");
      if (!lockBlueprint) throw new Error("Lock script not found in blueprint");

      const lockScriptBeforeApply = cborToScript(
        lockBlueprint.scriptBytes,
        "PlutusV3",
      );
      const appliedLock = applyParams(
        lockScriptBeforeApply.asPlutusV3()!.rawBytes(),
        Data.to(badgesBlueprint.hash),
      );
      const lockScript = cborToScript(appliedLock, "PlutusV3");

      setAppContext({
        loadedWallet: wallet,
        localStateUtxos: walletUtxos,
        badgesScript: {
          hash: badgesScript.hash(),
          validator: badgesScript,
          credential: badgesScriptCred,
        },
        uniqueMint: {
          pickedUtxo: headUtxo,
          pickedUtxoRef:
            headUtxo.input().transactionId() + "#" + headUtxo.input().index(),
          validator: mintScript,
          policyId: PolicyId(mintScript.hash()),
        },
        lockScript: {
          address: new Address({
            type: AddressType.EnterpriseScript,
            networkId,
            paymentPart: {
              type: CredentialType.ScriptHash,
              hash: lockScript.hash(),
            },
          }),
          validator: lockScript,
          hash: lockScript.hash(),
        },
      });

      setState("ParametersSet");
      setErrors("");
    } catch (err) {
      setErrors(
        err?.toString() || "Unknown error while trying to pick UTxO parameter",
      );
    }
  }

  async function registerScript() {
    try {
      const wallet = loadedWallet()!;
      const ctx = appContext()!;
      const tx = await blaze!
        .newTransaction()
        .addRegisterStake(ctx.badgesScript.credential)
        .provideScript(ctx.badgesScript.validator)
        .setChangeAddress(wallet.changeAddress)
        // .useEvaluator(uplcVm)
        .complete();
      const signedTx = await blaze!.signTransaction(tx);
      await wallet.api.postTransaction(signedTx);
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while registering script");
    }
  }

  async function mintBadge() {
    try {
      const wallet = loadedWallet()!;
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      console.log(ctx.uniqueMint.validator.hash());
      const tx = await blaze!
        .newTransaction()
        .addInput(ctx.uniqueMint.pickedUtxo)
        .addMint(policyId, new Map([[AssetName(""), 1n]]), Data.to([]))
        .provideScript(ctx.uniqueMint.validator)
        // .useEvaluator(uplcVm)
        .complete();

      const signedTx = await blaze!.signTransaction(tx);
      await wallet.api.postTransaction(signedTx);
      setLatestTx(signedTx);
      setBadgeUtxo(
        new TransactionUnspentOutput(
          new TransactionInput(tx.getId(), 0n),
          tx.body().outputs()[0],
        ),
      );

      setState("BadgeMintingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while minting the badge");
    }
  }

  async function lockAssets() {
    try {
      const wallet = loadedWallet()!;
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const tx = await blaze!
        .newTransaction()
        .lockLovelace(ctx.lockScript.address, 2000000n, Data.to(policyId))
        // .useEvaluator(uplcVm)
        .complete();

      const signedTx = await blaze!.signTransaction(tx);
      await wallet.api.postTransaction(signedTx);
      setLatestTx(signedTx);

      setState("LockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while locking the assets");
    }
  }

  async function unlockAssets() {
    try {
      const wallet = loadedWallet()!;
      const ctx = appContext()!;
      // The locked UTxO was the first output of the locking transaction
      const prevTx = latestTx()!;
      const prevTxId = prevTx.getId();
      const lockedOutput = prevTx.body().outputs()[0];
      const lockedUtxo = new TransactionUnspentOutput(
        new TransactionInput(prevTxId, 0n),
        lockedOutput,
      );

      // The unlock redeemer must contain the index of the badges withdraw redeemer
      // in the list of redeemer in the script context (for fast access).
      // This Tx will contain 2 redeemers:
      //  - one for the unlock script (spend purpose)
      //  - one for the badges verification script (withdraw purpose)
      // So since spend purposes are ordered first before withdrawals,
      // We know that the index of the badges verification withdraw redeemer will be 1 (0 is the unlock spend).
      // TODO: find that index reliably instead of hardcoded
      const unlockRedeemer = Data.to(1n);

      // For the badges verification withdraw script,
      // we must provide in the redeemer the list of presented badges,
      // as well as their index in the list of inputs or reference inputs.
      // TODO: find reliably the index of the ref input with the badge.
      const badgesRedeemer = Data.to(
        new Map([
          [
            ctx.uniqueMint.policyId,
            new Constr(
              0, // 0 for ref inputs, 1 for spent inputs
              [0n], // index of UTxO containing the badge in ref inputs. Hardcoded to 0 here since it’s the only ref input.
            ),
          ],
        ]),
      );

      // Extract the payment credential from the wallet address
      const walletKeyHash = Ed25519KeyHashHex(
        wallet.changeAddress.getProps().paymentPart?.hash!,
      );

      const tx = await blaze!
        .newTransaction()
        // collect the locked UTxO
        .addInput(lockedUtxo, unlockRedeemer)
        .provideScript(ctx.lockScript.validator)
        // Provide the badge proof to the verification withdraw script.
        // This also needs the wallet signature since it’s provided by reference.
        .addReferenceInput(badgeUtxo()!)
        .addRequiredSigner(walletKeyHash)
        // call the badges verification withdraw script (with 0 ada withdrawal)
        .addWithdrawal(
          RewardAccount.fromCredential(
            ctx.badgesScript.credential.value(),
            networkId,
          ),
          0n,
          badgesRedeemer,
        )
        .provideScript(ctx.badgesScript.validator)
        // .useEvaluator(uplcVm)
        .complete();

      const signedTx = await blaze!.signTransaction(tx);
      await wallet.api.postTransaction(signedTx);
      setLatestTx(signedTx);

      setState("UnlockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while unlocking the funds");
    }
  }

  async function burnBadge() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const tx = await blaze!
        .newTransaction()
        .addMint(PolicyId(policyId), new Map([[AssetName(""), -1n]]))
        .provideScript(ctx.uniqueMint.validator)
        // .useEvaluator(uplcVm)
        .complete();

      const signedTx = await blaze!.signTransaction(tx);
      await loadedWallet()!.api.postTransaction(signedTx);
      setLatestTx(signedTx);

      setState("BadgeBurningDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while burning the badge");
    }
  }

  // Display components ########################################################

  function viewErrors() {
    if (!errors()) return null;

    return (
      <pre style={{ color: "red" }}>
        <b>ERRORS: </b>
        {errors()}
      </pre>
    );
  }

  function viewLoadedWallet(wallet: LoadedWallet) {
    return (
      <>
        <img src={wallet.icon} height={32} alt="wallet icon" />
        <div>Wallet: {wallet.name}</div>
        {/* <div>Address: {Bytes.toHex(Address.toBytes(wallet.changeAddress))}</div> */}
        <div>UTxO count: {Object.keys(wallet.utxos ?? {}).length}</div>
      </>
    );
  }

  function viewAvailableWallets() {
    return (
      <div>
        {wallets().map((wallet: Cip30Wallet) => (
          <div>
            <img src={wallet.icon} height={32} alt="wallet icon" />
            {`name: ${wallet.name}`}
            <button
              onClick={async () => {
                const api = await wallet.enable();
                const webWallet = new WebWallet(api);
                const changeAddress = await webWallet.getChangeAddress();
                const utxos = await webWallet.getUnspentOutputs();
                blaze = await Blaze.from(provider!, webWallet);
                setLoadedWallet({
                  ...wallet,
                  api: webWallet,
                  changeAddress,
                  utxos,
                });
                setState("WalletConnected");
              }}
            >
              connect
            </button>
          </div>
        ))}
      </div>
    );
  }

  return (
    <div>
      <Show when={state() === "Startup"}>
        <div>Hello Cardano!</div>
      </Show>

      <Show when={state() === "WalletsDiscovered"}>
        <div>Hello Cardano!</div>
        <div>CIP-30 wallets detected:</div>
        {viewAvailableWallets()}
      </Show>

      <Show when={state() === "WalletConnected"}>
        {viewLoadedWallet(loadedWallet()!)}
        <button onClick={loadBlueprint}>Load Blueprints</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "BlueprintLoaded"}>
        {viewLoadedWallet(loadedWallet()!)}
        {scripts().map((script) => (
          <div>
            {script.hasParams
              ? `(unapplied) ${script.name} (size: ${script.scriptBytes.length / 2} bytes)`
              : `☑️ ${script.name} (size: ${script.scriptBytes.length / 2} bytes)`}
          </div>
        ))}
        <button onClick={pickUtxoParam}>
          Auto-pick UTxO to be spent for unicity guarantee of the mint contract
        </button>
        {viewErrors()}
      </Show>

      <Show when={state() === "ParametersSet"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>☑️ Picked UTxO: {appContext()!.uniqueMint.pickedUtxoRef}</div>
        <div>
          Minted token policy ID used as credential:{" "}
          {appContext()!.uniqueMint.policyId}
        </div>
        <div>Lock script hash: {appContext()!.lockScript.hash}</div>
        <div>Badges script hash: {appContext()!.badgesScript.hash}</div>

        <button onClick={mintBadge}>Mint the badge</button>
        <button onClick={registerScript}>
          Register the badges script (do only if needed)
        </button>

        {viewErrors()}
      </Show>

      <Show when={state() === "BadgeMintingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Token minting done</div>
        <div>Transaction ID: {latestTx()!.getId()}</div>
        <button onClick={lockAssets}>Lock 2 Ada with the badge as key</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "LockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets locking done</div>
        <div>Transaction ID: {latestTx()!.getId()}</div>
        <button onClick={unlockAssets}>
          Unlock the assets with the badge as key
        </button>
        {viewErrors()}
      </Show>

      <Show when={state() === "UnlockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets unlocked!</div>
        <div>Transaction ID: {latestTx()!.getId()}</div>
        <button onClick={burnBadge}>Burn the badge</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "BadgeBurningDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Token burning done</div>
        <div>Transaction ID: {latestTx()!.getId()}</div>
        {viewErrors()}
      </Show>
    </div>
  );
}

export default App;
