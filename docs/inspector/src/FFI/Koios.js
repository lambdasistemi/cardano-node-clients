// Koios CBOR fetch. Returns a Promise<string> of the hex, or throws.
//
// Koios is free and keyless for basic use (rate-limited). A bearer token
// can be supplied for higher limits; passed as empty string means no auth.
// Docs: https://api.koios.rest/

const BASES = {
  mainnet: "https://api.koios.rest/api/v1",
  preprod: "https://preprod.koios.rest/api/v1",
  preview: "https://preview.koios.rest/api/v1",
};

export const fetchTxCborImpl = (network) => (bearer) => (txHash) => async () => {
  const base = BASES[network] || BASES.mainnet;
  const headers = { "Content-Type": "application/json" };
  if (bearer && bearer.length > 0) {
    headers["Authorization"] = `Bearer ${bearer}`;
  }
  const resp = await fetch(`${base}/tx_cbor`, {
    method: "POST",
    headers,
    body: JSON.stringify({ _tx_hashes: [txHash] }),
  });
  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    throw new Error(`Koios ${resp.status}: ${body.slice(0, 200)}`);
  }
  const arr = await resp.json();
  if (!Array.isArray(arr) || arr.length === 0) {
    throw new Error("Koios: tx hash not found");
  }
  const entry = arr[0];
  if (!entry.cbor) {
    throw new Error(`Koios: response missing 'cbor' field: ${JSON.stringify(entry).slice(0, 200)}`);
  }
  return entry.cbor;
};
