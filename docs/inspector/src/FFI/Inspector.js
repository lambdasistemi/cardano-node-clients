// Thin wrapper over globalThis.runInspector (seeded by src/bootstrap.js).
// Returns a Promise<{ stdout, stderr, exitOk }>, mapped to Aff by the FFI.
export const runInspectorImpl = (stdinText) => () =>
  globalThis.runInspector(stdinText);

export const runInspectorRpcImpl = (txCbor) => (method) => (pathText) => () => {
  let path = [];
  try {
    const parsed = JSON.parse(pathText);
    if (Array.isArray(parsed)) path = parsed.map(String);
  } catch (_err) {
    path = [];
  }

  return globalThis.runInspector(
    JSON.stringify({
      tx_cbor: txCbor,
      method,
      path,
    })
  );
};
