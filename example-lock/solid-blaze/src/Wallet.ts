"use strict";

import { CIP30Interface } from "@blaze-cardano/sdk";

function cip30Discover(): Cip30Wallet[] {
  const wallets: Cip30Wallet[] = [];
  if ("cardano" in window) {
    const potentialWallets = window.cardano as { [key: string]: any };
    for (const walletId in potentialWallets) {
      const wallet: Cip30Wallet = potentialWallets[walletId];
      if (isCip30(wallet)) {
        wallets.push(wallet!);
      }
    }
  } else {
    console.log("Well there isn't any Cardano wallet here ^^");
  }
  return wallets;
}

function isCip30(wallet: any): boolean {
  return ["name", "icon", "apiVersion", "isEnabled"].every(
    (key) => key in wallet,
  );
}

export { cip30Discover };

export interface Cip30Wallet {
  name: string;
  icon: string;
  apiVersion: string;
  supportedExtensions?: string[];
  isEnabled: () => Promise<boolean>;
  enable: (extensions?: Array<{ cip: string }>) => Promise<CIP30Interface>;
}
