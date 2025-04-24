import { defineConfig } from "vite";
import solid from "vite-plugin-solid";
import wasm from "vite-plugin-wasm";
import topLevelAwait from "vite-plugin-top-level-await";
import { nodePolyfills } from "vite-plugin-node-polyfills";

export default defineConfig({
  plugins: [solid(), wasm(), topLevelAwait(), nodePolyfills()],
  optimizeDeps: {
    exclude: ["@anastasia-labs/cardano-multiplatform-lib-browser"],
  },
});
