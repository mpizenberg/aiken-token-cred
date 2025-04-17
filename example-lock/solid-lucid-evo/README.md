## Usage

Build the aiken code and copy the blueprints in this directory:

```sh
# from the root of the repo
aiken build
cp aiken-badges/plutus.json example-lock/solid-lucid-evo/badges-plutus.json
cp example-lock/aiken/plutus.json example-lock/solid-lucid-evo/lock-plutus.json
```

Then install and build and start the dev server:

```bash
# from this directory
bun install # or npm / pnpm / yarn
bun run dev
```
