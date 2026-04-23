// Thin wrapper over globalThis.runInspector (seeded by src/bootstrap.js).
// Returns a Promise<{ stdout, stderr, exitOk }>, mapped to Aff by the FFI.
export const runInspectorImpl = (stdinText) => () =>
  globalThis.runInspector(stdinText);
