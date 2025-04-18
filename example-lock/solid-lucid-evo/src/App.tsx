import { createSignal, Show } from "solid-js";
import { cip30Discover, Cip30Wallet } from "./Wallet.ts";
import {
  Address,
  applyDoubleCborEncoding,
  applyParamsToScript,
  Constr,
  Koios,
  Lucid,
  LucidEvolution,
  UTxO,
  Validator,
  validatorToAddress,
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
  | "ParametersSet";

type AppContext = {
  loadedWallet: LoadedWallet;
  localStateUtxos: UTxO[];
  badgesScript: {
    hash: string;
    validator: Validator;
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
    console.log("utxos", walletUtxos);

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
        new Constr(0, [
          new Constr(0, [headUtxo.txHash, BigInt(headUtxo.outputIndex)]),
        ]),
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
        },
        uniqueMint: {
          pickedUtxo: headUtxo,
          pickedUtxoRef: headUtxo.txHash + "#" + headUtxo.outputIndex,
          validator: mintScript,
          policyId: mintBlueprint.hash,
        },
        lockScript: {
          address: validatorToAddress(network, lockScript),
          validator: lockScript,
          hash: lockBlueprint.hash,
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

      <Show when={state() === "ParametersSet" && appContext() != null}>
        {viewLoadedWallet(appContext()!.loadedWallet)}
        <div>☑️ Picked UTxO: {appContext()!.uniqueMint.pickedUtxoRef}</div>
        <div>
          Minted token policy ID used as credential:{" "}
          {appContext()!.uniqueMint.policyId}
        </div>
        <div>Lock script hash: {appContext()!.lockScript.hash}</div>
        <div>Badges script hash: {appContext()!.badgesScript.hash}</div>

        {
          // TODO
          /* <button onClick={mintTokenKey}>Mint the token key</button>
        <button onClick={registerScript}>
          Register the token cred script (do only if needed)
        </button> */
        }
        {viewErrors()}
      </Show>
    </div>
  );
}

export default App;
