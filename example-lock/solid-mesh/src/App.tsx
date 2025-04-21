import { createSignal, Show } from "solid-js";
import {
  applyParamsToScript,
  BrowserWallet,
  mConStr,
  PlutusScript,
  serializePlutusScript,
  Wallet,
  UTxO,
  resolveScriptHash,
  deserializeAddress,
  MeshTxBuilder,
  ISubmitter,
  serializeRewardAddress,
  BlockfrostProvider,
} from "@meshsdk/core";
import { OfflineEvaluator } from "@meshsdk/core-csl";

type LoadedWallet = Wallet & {
  api: BrowserWallet;
  walletAddress: string;
  utxos: UTxO[];
  collateral: UTxO;
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
  localStateUtxos: UTxO[];
  badgesScript: {
    hash: string;
    validator: PlutusScript;
    rewardAddress: string;
  };
  uniqueMint: {
    pickedUtxo: UTxO;
    pickedUtxoRef: string;
    validator: PlutusScript;
    policyId: string;
  };
  lockScript: {
    address: string;
    validator: PlutusScript;
    hash: string;
  };
};

type UtxoRef = {
  txHash: string;
  outputIndex: number;
};

function App() {
  const networkId: 0 | 1 = 0; // 0 Testnet, 1 Mainnet
  const [state, setState] = createSignal<State>("Startup");
  const [wallets, setWallets] = createSignal<Wallet[]>([]);
  const [loadedWallet, setLoadedWallet] = createSignal<LoadedWallet | null>(
    null,
  );
  const [scripts, setScripts] = createSignal<Script[]>([]);
  const [appContext, setAppContext] = createSignal<AppContext | null>(null);
  const [badgeUtxoRef, setBadgeUtxoRef] = createSignal<UtxoRef | null>(null);
  const [latestTxId, setLatestTxId] = createSignal<string | null>(null);
  const [errors, setErrors] = createSignal("");

  // Initialize API provider (Kois doesn’t work with offline evaluator)
  // const koiosProvider = new KoiosProvider(
  //   "preview",
  //   import.meta.env.VITE_KOIOS_API_KEY,
  // );
  const blockfrostProvider = new BlockfrostProvider(
    import.meta.env.VITE_BLOCKFROST_PROJECT_ID,
  );
  const provider = blockfrostProvider;

  // Function to re-initialize the Tx builder each time.
  // Otherwise, it keeps in memory the previous intents.
  let txBuilderSubmitter: ISubmitter = provider;
  const txBuilder = () =>
    new MeshTxBuilder({
      evaluator: new OfflineEvaluator(provider, "preview"), // customize redeemer exec unit evaluation
      params: undefined, // customize protocol params
      fetcher: provider, // customize missing data fetcher
      submitter: txBuilderSubmitter, // customize Tx submission, later changed by the wallet
      serializer: undefined, // customize CBOR serializer
      verbose: true,
    });

  // Discover installed CIP-30 wallets
  (async () => {
    setWallets(await BrowserWallet.getAvailableWallets());
    setState("WalletsDiscovered");
  })();

  type Script = {
    name: string;
    scriptBytes: string;
    hash: string;
    hasParams: boolean;
  };

  function loadBlueprint() {
    const handleBlueprint = (result: {
      ok: boolean;
      data?: Script[];
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

      const appliedMint = applyParamsToScript(mintBlueprint.scriptBytes, [
        // Convert headUtxo reference into Data
        mConStr(0, [headUtxo.input.txHash, BigInt(headUtxo.input.outputIndex)]),
      ]);
      const mintScript: PlutusScript = {
        version: "V3",
        code: appliedMint,
      };

      // Find badges script in blueprint
      const badgesBlueprint = scripts().find(
        (s) => s.name === "check_badges.check_badges.withdraw",
      );
      if (!badgesBlueprint)
        throw new Error("Badges script not found in blueprint");

      const badgesScriptHash = badgesBlueprint.hash;
      const badgesScript: PlutusScript = {
        version: "V3",
        code: applyParamsToScript(badgesBlueprint.scriptBytes, []),
      };
      const badgesScriptRewardAddress: string = serializeRewardAddress(
        badgesScriptHash,
        true,
        networkId,
      );

      // Find lock script in blueprint
      const lockBlueprint = scripts().find((s) => s.name === "lock.lock.spend");
      if (!lockBlueprint) throw new Error("Lock script not found in blueprint");

      const appliedLock = applyParamsToScript(lockBlueprint.scriptBytes, [
        badgesScriptHash,
      ]);
      const lockScript: PlutusScript = {
        version: "V3",
        code: appliedLock,
      };
      const lockScriptAddress: string = serializePlutusScript(
        lockScript,
        undefined,
        networkId,
      ).address;

      setAppContext({
        loadedWallet: wallet,
        localStateUtxos: walletUtxos,
        badgesScript: {
          hash: badgesScriptHash,
          validator: badgesScript,
          rewardAddress: badgesScriptRewardAddress,
        },
        uniqueMint: {
          pickedUtxo: headUtxo,
          pickedUtxoRef:
            headUtxo.input.txHash + "#" + headUtxo.input.outputIndex,
          validator: mintScript,
          policyId: resolveScriptHash(mintScript.code, mintScript.version),
        },
        lockScript: {
          address: lockScriptAddress,
          validator: lockScript,
          hash: resolveScriptHash(lockScript.code, lockScript.version),
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
      const ctx = appContext()!;
      const wallet = loadedWallet()!;
      const walletAddress = wallet.walletAddress;
      const collateral = wallet.collateral;
      const utxos = await wallet.api.getUtxos();
      setLoadedWallet({ ...wallet, utxos });

      const tx = await txBuilder()
        .registerStakeCertificate(ctx.badgesScript.rewardAddress)
        .certificateScript(
          ctx.badgesScript.validator.code,
          ctx.badgesScript.validator.version,
        )
        // send change back to wallet
        .changeAddress(walletAddress)
        // Provide the list of UTxOs to use for selection
        .selectUtxosFrom(utxos)
        // set collateral
        // Remark: this could fail if the wallet has no UTxO "declared" for collateral
        .txInCollateral(
          collateral.input.txHash,
          collateral.input.outputIndex,
          collateral.output.amount,
          collateral.output.address,
        )
        .complete();
      const signedTx = await wallet.api.signTx(tx);
      await wallet.api.submitTx(signedTx);
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while registering script");
    }
  }

  async function mintBadge() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const pickedUtxo = ctx.uniqueMint.pickedUtxo;
      const wallet = loadedWallet()!;
      const walletAddress = wallet.walletAddress;
      const collateral = wallet.collateral;
      const utxos = await wallet.api.getUtxos();
      setLoadedWallet({ ...wallet, utxos });

      const tx = await txBuilder()
        // required UTxO to be spent (for unicity)
        .txIn(
          pickedUtxo.input.txHash,
          pickedUtxo.input.outputIndex,
          pickedUtxo.output.amount, // optional, but can avoid api provider requests
          pickedUtxo.output.address, // optional, but can avoid api provider requests
          0, // script size: optional, but can avoid api provider requests
        )
        // Badge being minted
        .mintPlutusScript(ctx.uniqueMint.validator.version)
        .mint("1", policyId, "")
        .mintingScript(ctx.uniqueMint.validator.code)
        .mintRedeemerValue([])
        // send change back to wallet
        .changeAddress(walletAddress)
        // Provide the list of UTxOs to use for selection
        .selectUtxosFrom(utxos) // TODO: should I remove pickedUtxo from that?
        // set collateral
        // Remark: this could fail if the wallet has no UTxO "declared" for collateral
        .txInCollateral(
          collateral.input.txHash,
          collateral.input.outputIndex,
          collateral.output.amount,
          collateral.output.address,
        )
        .complete();

      const signedTx = await wallet.api.signTx(tx);
      const txId = await wallet.api.submitTx(signedTx);
      setLatestTxId(txId);

      // TODO: actually make sure the output index is correct instead of hardcoding it to 0
      setBadgeUtxoRef({ txHash: txId, outputIndex: 0 });

      setState("BadgeMintingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while minting the badge");
    }
  }

  async function lockAssets() {
    try {
      const ctx = appContext()!;
      const lockAddress = ctx.lockScript.address;
      const policyId = ctx.uniqueMint.policyId;
      const wallet = loadedWallet()!;
      const walletAddress = wallet.walletAddress;
      const collateral = wallet.collateral;
      const utxos = await wallet.api.getUtxos();
      setLoadedWallet({ ...wallet, utxos });

      // Build the Tx
      // Let the fetcher get the list of UTxOs for selection
      const tx = await txBuilder()
        // Send 2 ada to the lock address
        .txOut(lockAddress, [{ unit: "", quantity: "2000000" }])
        .txOutInlineDatumValue(policyId) // not working
        // .txOutDatumEmbedValue(policyId) // not working
        // send change back to wallet
        .changeAddress(walletAddress)
        // Provide the list of UTxOs to use for selection
        .selectUtxosFrom(utxos)
        // set collateral
        // Remark: this could fail if the wallet has no UTxO "fit" for collateral
        .txInCollateral(
          collateral.input.txHash,
          collateral.input.outputIndex,
          collateral.output.amount,
          collateral.output.address,
        )
        .complete();

      const signedTx = await wallet.api.signTx(tx);
      const txId = await wallet.api.submitTx(signedTx);
      setLatestTxId(txId);

      setState("LockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while locking the assets");
    }
  }

  async function unlockAssets() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const wallet = loadedWallet()!;
      const walletAddress = wallet.walletAddress;
      const collateral = wallet.collateral;
      const utxos = await wallet.api.getUtxos();
      setLoadedWallet({ ...wallet, utxos });

      // The locked UTxO was the first output of the locking transaction
      const lockedUtxoRef = { txHash: latestTxId()!, outputIndex: 0 };

      // The unlock redeemer must contain the index of the badges withdraw redeemer
      // in the list of redeemer in the script context (for fast access).
      // This Tx will contain 2 redeemers:
      //  - one for the unlock script (spend purpose)
      //  - one for the badges verification script (withdraw purpose)
      // So since spend purposes are ordered first before withdrawals,
      // We know that the index of the badges verification withdraw redeemer will be 1 (0 is the unlock spend).
      // TODO: find that index reliably instead of hardcoded
      // const unlockRedeemer = 1n; // TypeError: Do not know how to serialize a BigInt
      const unlockRedeemer = 1;

      // For the badges verification withdraw script,
      // we must provide in the redeemer the list of presented badges,
      // as well as their index in the list of inputs or reference inputs.
      // TODO: find reliably the index of the ref input with the badge.
      const badgesRedeemer = new Map([
        [
          ctx.uniqueMint.policyId,
          mConStr(
            0, // 0 for ref inputs, 1 for spent inputs
            // [0n], // TypeError: Do not know how to serialize a BigInt
            [0], // index of UTxO containing the badge in ref inputs. Hardcoded to 0 here since it’s the only ref input.
          ),
        ],
      ]);

      // Extract the payment credential from the wallet address
      const walletKeyHash = deserializeAddress(walletAddress).pubKeyHash;

      const tx = await txBuilder()
        // collect the locked UTxO
        .spendingPlutusScript(ctx.lockScript.validator.version)
        .txIn(lockedUtxoRef.txHash, lockedUtxoRef.outputIndex)
        .txInDatumValue(policyId)
        .txInInlineDatumPresent()
        .txInRedeemerValue(unlockRedeemer)
        .txInScript(ctx.lockScript.validator.code)
        // Provide the badge proof to the verification withdraw script.
        // This also needs the wallet signature since it’s provided by reference.
        .readOnlyTxInReference(
          badgeUtxoRef()!.txHash,
          badgeUtxoRef()!.outputIndex,
        )
        .requiredSignerHash(walletKeyHash)
        // call the badges verification withdraw script (with 0 ada withdrawal)
        .withdrawalPlutusScript(ctx.badgesScript.validator.version)
        .withdrawal(ctx.badgesScript.rewardAddress, "0")
        .withdrawalRedeemerValue(badgesRedeemer)
        .withdrawalScript(ctx.badgesScript.validator.code)
        // send change back to wallet
        .changeAddress(walletAddress)
        // Provide the list of UTxOs to use for selection
        .selectUtxosFrom(utxos)
        // set collateral
        // Remark: this could fail if the wallet has no UTxO "fit" for collateral
        .txInCollateral(
          collateral.input.txHash,
          collateral.input.outputIndex,
          collateral.output.amount,
          collateral.output.address,
        )
        .complete();

      const signedTx = await wallet.api.signTx(tx, true); // partial sign needed by Eternl (wallet bug)
      const txId = await wallet.api.submitTx(signedTx);
      setLatestTxId(txId);

      setState("UnlockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while unlocking the funds");
    }
  }

  async function burnBadge() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const wallet = loadedWallet()!;
      const walletAddress = wallet.walletAddress;
      const collateral = wallet.collateral;
      const utxos = await wallet.api.getUtxos();
      setLoadedWallet({ ...wallet, utxos });

      const tx = await txBuilder()
        // TODO: Do we need to specify which UTxO to spend to find the badge?
        // Badge being burned
        .mintPlutusScript(ctx.uniqueMint.validator.version)
        .mint("-1", policyId, "")
        .mintingScript(ctx.uniqueMint.validator.code)
        .mintRedeemerValue([])
        // send change back to wallet
        .changeAddress(walletAddress)
        // Provide the list of UTxOs to use for selection
        .selectUtxosFrom(utxos)
        // set collateral
        // Remark: this could fail if the wallet has no UTxO "fit" for collateral
        .txInCollateral(
          collateral.input.txHash,
          collateral.input.outputIndex,
          collateral.output.amount,
          collateral.output.address,
        )
        .complete();

      const signedTx = await wallet.api.signTx(tx);
      const txId = await wallet.api.submitTx(signedTx);
      setLatestTxId(txId);

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
        {wallets().map((wallet: Wallet) => (
          <div>
            <img src={wallet.icon} height={32} alt="wallet icon" />
            {`name: ${wallet.name}`}
            <button
              onClick={async () => {
                const api = await BrowserWallet.enable(wallet.id);
                txBuilderSubmitter = api; // Use wallet to submit Txs
                setLoadedWallet({
                  ...wallet,
                  api,
                  utxos: await api.getUtxos(),
                  collateral: (await api.getCollateral())[0],
                  walletAddress: await api.getChangeAddress(),
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
        <div>Transaction ID: {latestTxId()!}</div>
        <button onClick={lockAssets}>Lock 2 Ada with the badge as key</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "LockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets locking done</div>
        <div>Transaction ID: {latestTxId()!}</div>
        <button onClick={unlockAssets}>
          Unlock the assets with the badge as key
        </button>
        {viewErrors()}
      </Show>

      <Show when={state() === "UnlockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets unlocked!</div>
        <div>Transaction ID: {latestTxId()!}</div>
        <button onClick={burnBadge}>Burn the badge</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "BadgeBurningDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Token burning done</div>
        <div>Transaction ID: {latestTxId()!}</div>
        {viewErrors()}
      </Show>
    </div>
  );
}

export default App;
