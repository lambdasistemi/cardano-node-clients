// Pretty-print a JSON string by parsing + re-stringifying with 2-space indent.
// If the input isn't valid JSON, return it unchanged.
export const prettyImpl = (text) => {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch (e) {
    return text;
  }
};

const emptyInspection = (title, subtitle = "") => ({
  valid: false,
  title,
  subtitle,
  metrics: [],
  outputs: [],
  mint: [],
  inputs: [],
  referenceInputs: [],
  outputNote: "",
  mintNote: "",
  inputNote: "",
});

const text = (value) =>
  value === null || value === undefined ? "" : String(value);

const shortHex = (value, head = 12, tail = 8) => {
  const s = text(value);
  if (s.length <= head + tail + 1) return s;
  return `${s.slice(0, head)}...${s.slice(-tail)}`;
};

const formatLovelace = (value) => {
  const raw = text(value);
  if (raw === "") return "n/a";

  try {
    const lovelace = BigInt(raw);
    const ada = lovelace / 1000000n;
    const fraction = (lovelace % 1000000n)
      .toString()
      .padStart(6, "0")
      .replace(/0+$/, "");

    return fraction === "" ? `${ada} ADA` : `${ada}.${fraction} ADA`;
  } catch (_err) {
    return raw;
  }
};

const policyEntries = (assets) =>
  assets && typeof assets === "object" && !Array.isArray(assets)
    ? Object.entries(assets)
    : [];

const assetCount = (assets) =>
  policyEntries(assets).reduce((total, [, policyAssets]) => {
    if (!policyAssets || typeof policyAssets !== "object") return total;
    return total + Object.keys(policyAssets).length;
  }, 0);

const policyCount = (assets) => policyEntries(assets).length;

const plural = (count, singular, pluralText = `${singular}s`) =>
  `${count} ${count === 1 ? singular : pluralText}`;

const assetLabel = (assets) => {
  const assetsN = assetCount(assets);
  const policiesN = policyCount(assets);
  if (assetsN === 0) return "none";
  return `${plural(assetsN, "asset")} / ${plural(policiesN, "policy", "policies")}`;
};

const datumLabel = (datum) => {
  if (!datum || typeof datum !== "object") return "unknown";
  switch (datum.kind) {
    case "no_datum":
      return "none";
    case "datum_hash":
      return `hash ${shortHex(datum.hash)}`;
    case "inline_datum":
      return "inline datum";
    default:
      return text(datum.kind || "unknown").replace(/_/g, " ");
  }
};

const txInLabel = (input) => {
  if (!input || typeof input !== "object") return text(input);
  return `${shortHex(input.tx_id)}#${text(input.index)}`;
};

const validityLabel = (slot) => (slot === null || slot === undefined ? "open" : text(slot));

const metric = (label, value) => ({ label, value: text(value) });

export const inspectImpl = (raw) => {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (_err) {
    return emptyInspection("Raw output", "The decoder did not return JSON.");
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return emptyInspection("Raw output", "The decoder returned a non-object JSON value.");
  }

  const outputs = Array.isArray(parsed.outputs) ? parsed.outputs : [];
  const inputs = Array.isArray(parsed.inputs) ? parsed.inputs : [];
  const referenceInputs = Array.isArray(parsed.reference_inputs)
    ? parsed.reference_inputs
    : [];
  const mint = parsed.mint && typeof parsed.mint === "object" ? parsed.mint : {};
  const validity =
    parsed.validity_interval && typeof parsed.validity_interval === "object"
      ? parsed.validity_interval
      : {};

  const totalOutputAssets = outputs.reduce(
    (total, output) => total + assetCount(output && output.assets),
    0
  );
  const mintedAssets = assetCount(mint);

  const outputRows = outputs.slice(0, 8).map((output, index) => ({
    index: `#${index}`,
    address: shortHex(output && output.address_hex, 18, 10),
    coin: formatLovelace(output && output.coin_lovelace),
    assets: assetLabel(output && output.assets),
    datum: datumLabel(output && output.datum),
  }));

  const mintRows = policyEntries(mint)
    .slice(0, 8)
    .map(([policy, assets]) => ({
      policy: shortHex(policy, 14, 10),
      assets: assetLabel({ [policy]: assets }),
    }));

  const inputRows = inputs.slice(0, 8).map(txInLabel);
  const referenceInputRows = referenceInputs.slice(0, 8).map(txInLabel);

  return {
    valid: true,
    title: `${text(parsed.era || "Decoded")} transaction`,
    subtitle: text(parsed.decoder || ""),
    metrics: [
      metric("Fee", formatLovelace(parsed.fee_lovelace)),
      metric("Inputs", parsed.input_count ?? inputs.length),
      metric("Reference inputs", parsed.reference_input_count ?? referenceInputs.length),
      metric("Outputs", parsed.output_count ?? outputs.length),
      metric("Output assets", totalOutputAssets),
      metric("Mint policies", policyCount(mint)),
      metric("Minted assets", mintedAssets),
      metric("Certificates", parsed.cert_count ?? 0),
      metric("Withdrawals", parsed.withdrawal_count ?? 0),
      metric("Required signers", parsed.required_signer_count ?? 0),
      metric("Valid from", validityLabel(validity.invalid_before)),
      metric("Valid until", validityLabel(validity.invalid_hereafter)),
    ],
    outputs: outputRows,
    mint: mintRows,
    inputs: inputRows,
    referenceInputs: referenceInputRows,
    outputNote:
      outputs.length > outputRows.length
        ? `Showing first ${outputRows.length} of ${outputs.length} outputs.`
        : "",
    mintNote:
      policyCount(mint) > mintRows.length
        ? `Showing first ${mintRows.length} of ${policyCount(mint)} mint policies.`
        : "",
    inputNote:
      inputs.length + referenceInputs.length > inputRows.length + referenceInputRows.length
        ? "Input previews are truncated."
        : "",
  };
};
