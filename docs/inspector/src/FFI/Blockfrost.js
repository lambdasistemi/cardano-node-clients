// Blockfrost CBOR fetch. Returns a Promise<string> of the hex, or throws.
// Project ID goes in the header (not URL) to avoid leaking via Referer/logs.

const BASES = {
  mainnet: "https://cardano-mainnet.blockfrost.io/api/v0",
  preprod: "https://cardano-preprod.blockfrost.io/api/v0",
  preview: "https://cardano-preview.blockfrost.io/api/v0",
};

export const fetchTxCborImpl = (network) => (projectId) => (txHash) => async () => {
  const base = BASES[network] || BASES.mainnet;
  const resp = await fetch(`${base}/txs/${txHash}/cbor`, {
    headers: { project_id: projectId },
  });
  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    throw new Error(`Blockfrost ${resp.status}: ${body.slice(0, 200)}`);
  }
  const json = await resp.json();
  return json.cbor;
};
