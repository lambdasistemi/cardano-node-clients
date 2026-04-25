// Bootstrap: load @bjorn3/browser_wasi_shim, instantiate the inspector WASM
// (copied into src/assets/inspector.wasm at Nix build time via --loader:.wasm=binary),
// and expose a `runInspector(stdin: string) -> Promise<{ stdout, stderr, exitOk }>`
// on globalThis. The PureScript FFI then wraps this global in Aff.

import { WASI, File, OpenFile, ConsoleStdout }
  from "@bjorn3/browser_wasi_shim";
import wasmBytes from "./assets/inspector.wasm";

const compiledModulePromise = WebAssembly.compile(wasmBytes);

globalThis.runInspector = async (stdinText) => {
  const stdin = new OpenFile(
    new File(new TextEncoder().encode(stdinText))
  );
  const stdoutLines = [];
  const stderrLines = [];
  const stdout = ConsoleStdout.lineBuffered((l) => stdoutLines.push(l));
  const stderr = ConsoleStdout.lineBuffered((l) => stderrLines.push(l));

  const wasi = new WASI([], [], [stdin, stdout, stderr]);
  const mod = await compiledModulePromise;
  const inst = await WebAssembly.instantiate(mod, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });

  let exitOk = true;
  try {
    wasi.start(inst);
  } catch (err) {
    // WASI `proc_exit` manifests as a throw; the shim uses a non-zero exit
    // code to signal an abnormal termination. Inspect err.code if available.
    exitOk = false;
    stderrLines.push(String(err));
  }

  return {
    stdout: stdoutLines.join("\n"),
    stderr: stderrLines.join("\n"),
    exitOk,
  };
};
