import { createSignal, Show } from "solid-js";
import {
  Wallet,
  NetworkType,
} from "@cardano-foundation/cardano-connect-with-wallet-core";

type WalletDescriptor = {
  id: string;
  name: string;
};

type LoadedWallet = {
  id: string;
  name: string;
  stakeAddress: string | null;
  utxos: Record<string, unknown>;
};

function App() {
  const network = NetworkType.TESTNET;
  const [state, setState] = createSignal("Startup");
  const [wallets, setWallets] = createSignal<WalletDescriptor[]>([]);
  const [loadedWallet, setLoadedWallet] = createSignal<LoadedWallet | null>(
    null,
  );
  const [scripts, setScripts] = createSignal<Script[]>([]);
  const [errors, setErrors] = createSignal("");

  Wallet.addEventListener("stakeAddress", (value) => {
    const stakeAddress = typeof value === "string" ? value : null;
    console.log("Stake address event:", stakeAddress);
    // update loadedWallet if it is defined
    console.log("loadedWallet:", loadedWallet());
    if (loadedWallet()) {
      setLoadedWallet({
        ...loadedWallet()!,
        stakeAddress: stakeAddress,
      });
    }
  });

  (async function discoverWallets() {
    try {
      // Discover installed wallets
      const discoveredWallets = Wallet.getInstalledWalletExtensions();
      // Retrieve the name and icon for each wallet
      setWallets(
        discoveredWallets.map((walletId) => ({
          id: walletId,
          name: walletId, // TODO: no way to get the human-friendly name?
          // icon: Wallet.?, // TODO: no api to get the wallet icon?
        })),
      );
      setState("WalletsDiscovered");
    } catch (error: unknown) {
      setErrors(error instanceof Error ? error.message : String(error));
      setState("Startup");
    }
  })();

  function walletConnected() {
    setState("WalletConnected");
    // Load the wallet UTxOs how to?
  }

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

    // In a real app, this would be fetch calls to the JSON files
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

  // Display components ########################################################

  function displayErrors() {
    if (!errors()) return null;

    return (
      <pre style={{ color: "red" }}>
        <b>ERRORS: </b>
        {errors()}
      </pre>
    );
  }

  function viewLoadedWallet(wallet: LoadedWallet | null) {
    return (
      <>
        <div>Wallet: {wallet?.name}</div>
        <div>Stake Address: {wallet?.stakeAddress}</div>
        {/* <div>Address: {Bytes.toHex(Address.toBytes(wallet.changeAddress))}</div> */}
        <div>UTxO count: {Object.keys(wallet?.utxos ?? {}).length}</div>
      </>
    );
  }

  function viewAvailableWallets() {
    return (
      <div>
        {wallets().map((wallet) => (
          <div>
            {/* <img src={wallet.icon} height={32} alt="wallet icon" /> */}
            {`id: ${wallet.id}, name: ${wallet.name}`}
            <button
              onClick={() => {
                setLoadedWallet({
                  ...wallet,
                  stakeAddress: null,
                  utxos: {},
                });
                Wallet.connect(
                  wallet.id,
                  network,
                  () => walletConnected(), // onConnect
                  (code) => console.error(code), // onError
                );
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
        {viewLoadedWallet(loadedWallet())}
        <button onClick={loadBlueprint}>Load Blueprints</button>
        {displayErrors()}
      </Show>

      <Show when={state() === "BlueprintLoaded"}>
        {viewLoadedWallet(loadedWallet())}
        {scripts().map((script) => (
          <div>
            {script.hasParams
              ? `(unapplied) ${script.name} (size: ${script.scriptBytes.length / 2} bytes)`
              : `☑️ ${script.name} (size: ${script.scriptBytes.length / 2} bytes)`}
          </div>
        ))}
        {/* <button onClick={pickUtxoParam}>
          Auto-pick UTxO to be spent for unicity guarantee of the mint contract
        </button> */}
        {displayErrors()}
      </Show>
    </div>
  );
}

export default App;
