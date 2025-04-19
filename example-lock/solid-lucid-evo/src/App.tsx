import { createSignal, Show } from "solid-js";
import { cip30Discover, Cip30Wallet } from "./Wallet.ts";
import {
  Address,
  applyDoubleCborEncoding,
  applyParamsToScript,
  Constr,
  Data,
  fromText,
  Koios,
  Lucid,
  LucidEvolution,
  mintingPolicyToId,
  OutRef,
  RewardAddress,
  UTxO,
  Validator,
  validatorToAddress,
  validatorToRewardAddress,
  validatorToScriptHash,
  WalletApi,
} from "@lucid-evolution/lucid";

type LoadedWallet = Cip30Wallet & {
  api: WalletApi;
  utxos: UTxO[] | undefined;
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
    validator: Validator;
    rewardAddress: RewardAddress;
  };
  uniqueMint: {
    pickedUtxo: UTxO;
    pickedUtxoRef: string;
    validator: Validator;
    policyId: string;
  };
  lockScript: {
    address: Address;
    validator: Validator;
    hash: string;
  };
};

function App() {
  const network: "Preview" | "Mainnet" = "Preview";
  const [state, setState] = createSignal<State>("Startup");
  const [wallets, setWallets] = createSignal<Cip30Wallet[]>([]);
  const [loadedWallet, setLoadedWallet] = createSignal<LoadedWallet | null>(
    null,
  );
  const [scripts, setScripts] = createSignal<Script[]>([]);
  const [appContext, setAppContext] = createSignal<AppContext | null>(null);
  const [txId, setTxId] = createSignal<string | null>(null);
  const [errors, setErrors] = createSignal("");

  // Initialize Lucid Evolution library with some API provider
  let lucid: LucidEvolution | null = null;
  (async () => {
    lucid = await Lucid(
      new Koios(
        "https://preview.koios.rest/api/v1",
        import.meta.env.VITE_KOIOS_API_KEY,
      ),
      "Preview",
    );
  })();

  // Discover installed CIP-30 wallets
  setWallets(cip30Discover());
  setState("WalletsDiscovered");

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
        new Constr(0, [headUtxo.txHash, BigInt(headUtxo.outputIndex)]),
      ]);
      const mintScript: Validator = {
        type: "PlutusV3",
        script: appliedMint,
      };

      // Find badges script in blueprint
      const badgesBlueprint = scripts().find(
        (s) => s.name === "check_badges.check_badges.withdraw",
      );
      if (!badgesBlueprint)
        throw new Error("Badges script not found in blueprint");

      const badgesScriptHash = badgesBlueprint.hash;
      const badgesScript: Validator = {
        type: "PlutusV3",
        script: applyDoubleCborEncoding(badgesBlueprint.scriptBytes),
      };
      const badgesScriptRewardAddress: RewardAddress = validatorToRewardAddress(
        network,
        badgesScript,
      );

      // Find lock script in blueprint
      const lockBlueprint = scripts().find((s) => s.name === "lock.lock.spend");
      if (!lockBlueprint) throw new Error("Lock script not found in blueprint");

      const appliedLock = applyParamsToScript(lockBlueprint.scriptBytes, [
        badgesScriptHash,
      ]);
      const lockScript: Validator = {
        type: "PlutusV3",
        script: appliedLock,
      };

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
          pickedUtxoRef: headUtxo.txHash + "#" + headUtxo.outputIndex,
          validator: mintScript,
          policyId: mintingPolicyToId(mintScript),
        },
        lockScript: {
          address: validatorToAddress(network, lockScript),
          validator: lockScript,
          hash: validatorToScriptHash(lockScript),
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
      const tx = await lucid!
        .newTx()
        .register.Stake(ctx.badgesScript.rewardAddress)
        .attach.Script(ctx.badgesScript.validator)
        .complete();
      const signedTx = await tx.sign.withWallet().complete();
      await signedTx.submit();
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while registering script");
    }
  }

  async function mintBadge() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const tx = await lucid!
        .newTx()
        .collectFrom([ctx.uniqueMint.pickedUtxo]) // required UTxO to be spent (for unicity)
        .mintAssets(
          {
            [policyId + fromText("")]: 1n,
          },
          Data.to([]),
        )
        .attach.Script(ctx.uniqueMint.validator)
        .complete();

      const signedTx = await tx.sign.withWallet().complete();
      const mintTxId = await signedTx.submit();
      setTxId(mintTxId);

      setState("BadgeMintingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while minting the badge");
    }
  }

  async function lockAssets() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const tx = await lucid!
        .newTx()
        .pay.ToContract(
          ctx.lockScript.address,
          {
            kind: "inline",
            value: Data.to(policyId),
          },
          { lovelace: 2000000n },
        )
        .complete();
      const signedTx = await tx.sign.withWallet().complete();
      const mintTxId = await signedTx.submit();
      setTxId(mintTxId);

      setState("LockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while locking the assets");
    }
  }

  async function unlockAssets() {
    try {
      const ctx = appContext()!;
      // The locked UTxO was the first output of the locking transaction
      console.log("hello 1");
      const lockedUtxoRef: OutRef = { txHash: txId()!, outputIndex: 0 };
      const lockedUtxo = (await lucid!.utxosByOutRef([lockedUtxoRef]))[0];
      console.log("hello 2");

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

      // Retrieve the UTxO containing the badge used to unlock the funds
      console.log("hello 3");
      const badgeUtxo = await lucid!.utxoByUnit(
        ctx.uniqueMint.policyId + fromText(""),
      );
      console.log("hello 4");

      const tx = await lucid!
        .newTx()
        // collect the locked UTxO
        .collectFrom([lockedUtxo], unlockRedeemer)
        .attach.Script(ctx.lockScript.validator)
        // provide the badge proof to the verification withdraw script
        .readFrom([badgeUtxo])
        // call the badges verification withdraw script (with 0 ada withdrawal)
        .withdraw(ctx.badgesScript.rewardAddress, 0n, badgesRedeemer)
        .attach.Script(ctx.badgesScript.validator)
        .complete();

      const signedTx = await tx.sign.withWallet().complete();
      const unlockTxId = await signedTx.submit();
      setTxId(unlockTxId);

      setState("UnlockingDone");
    } catch (err) {
      setErrors(err?.toString() || "Unknown error while unlocking the funds");
    }
  }

  async function burnBadge() {
    try {
      const ctx = appContext()!;
      const policyId = ctx.uniqueMint.policyId;
      const tx = await lucid!
        .newTx()
        .mintAssets(
          {
            [policyId + fromText("")]: -1n,
          },
          Data.to([]),
        )
        .attach.Script(ctx.uniqueMint.validator)
        .complete();

      const signedTx = await tx.sign.withWallet().complete();
      const burnTxId = await signedTx.submit();
      setTxId(burnTxId);

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
                lucid?.selectWallet.fromAPI(api);
                const utxos = await lucid?.wallet().getUtxos();
                setLoadedWallet({
                  ...wallet,
                  api,
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
        <div>Transaction ID: {txId()}</div>
        <button onClick={lockAssets}>Lock 2 Ada with the badge as key</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "LockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets locking done</div>
        <div>Transaction ID: {txId()}</div>
        <button onClick={unlockAssets}>
          Unlock the assets with the badge as key
        </button>
        {viewErrors()}
      </Show>

      <Show when={state() === "UnlockingDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Assets unlocked!</div>
        <div>Transaction ID: {txId()}</div>
        <button onClick={burnBadge}>Burn the badge</button>
        {viewErrors()}
      </Show>

      <Show when={state() === "BadgeBurningDone"}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>Token burning done</div>
        <div>Transaction ID: {txId()}</div>
        {viewErrors()}
      </Show>
    </div>
  );
}

export default App;
