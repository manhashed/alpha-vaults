/**
 * Shared configuration for deployment scripts
 */

export interface NetworkConfig {
  chainId: number;
  explorerUrl: string;
  usdc: string;
  felixVault: string;
  hlpVault: string;
  tradingVault: string;
  coreDepositor: string;
  perpsTokenId: bigint;
  perpsTokenScale: bigint;
  perpDexIndex: number;
}

export const NETWORK_CONFIG: Record<string, NetworkConfig> = {
  hyperEvmTestnet: {
    chainId: 998,
    explorerUrl: "https://testnet.purrsec.com",
    usdc: "0x...", // TODO: Update with testnet USDC
    felixVault: "0x...", // TODO: Update when available
    hlpVault: "0xa15099a30bbf2e68942d6f4c43d70d04faeab0a0",
    tradingVault: "0x...", // TODO: Update with trading vault address
    coreDepositor: "0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206",
    perpsTokenId: 0n,
    perpsTokenScale: 1_000_000n,
    perpDexIndex: 0,
  },
  hyperEvmMainnet: {
    chainId: 999,
    explorerUrl: "https://hyperevmscan.io",
    usdc: "0xb88339CB7199b77E23DB6E890353E22632Ba630f",
    felixVault: "0x8A862fD6c12f9ad34C9c2ff45AB2b6712e8CEa27",
    hlpVault: "0xdfc24b077bc1425AD1DEA75bCB6f8158E10Df303",
    tradingVault: "0xb1505ad1a4c7755e0eb236aa2f4327bfc3474768",
    coreDepositor: "0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24",
    perpsTokenId: 0n,
    perpsTokenScale: 1_000_000n,
    perpDexIndex: 0,
  },
};

export function getNetworkConfig(networkName: string): NetworkConfig {
  const config = NETWORK_CONFIG[networkName];
  if (!config) {
    throw new Error(`Unknown network: ${networkName}`);
  }
  return config;
}

export function isMainnet(networkName: string): boolean {
  return networkName === "hyperEvmMainnet";
}
