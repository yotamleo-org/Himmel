// HIMMEL-4620: the config UI's read and write of the `vm` section of ~/.himmel/config.json.
// Everything goes through luna-config.js: validateVm (the mirror of scripts/lib/vm-mode.sh) runs before
// the write, save() is atomic, and no other section is built here: the rest of the document is whatever
// inspect() loaded.
import { inspect, save, validateVm } from "../himmelctl/lib/luna-config.js";

export type VmView = { mode: string; remote: Record<string, unknown> | null };
export type VmResult = { status: number; body: VmView | { error: string } };

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

// The effective setting: an absent section is the resolver's default, local.
export function readVm(): VmResult {
  let doc: Record<string, unknown>;
  try { doc = inspect().doc; } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
  const vm = isObject(doc.vm) ? doc.vm : {};
  return { status: 200, body: { mode: typeof vm.mode === "string" ? vm.mode : "local", remote: isObject(vm.remote) ? vm.remote : null } };
}

// local and none carry no remote; remote carries ssh, and port / identity only when given
// (an absent one takes the resolver's default). A numeric-string port is stored as a number.
function toVm(b: Record<string, unknown>): Record<string, unknown> {
  const vm: Record<string, unknown> = { mode: b.mode };
  if (b.mode !== "remote") return vm;
  const r = isObject(b.remote) ? b.remote : {};
  const remote: Record<string, unknown> = { ssh: r.ssh ?? "" };
  if (r.port !== undefined && r.port !== null && r.port !== "") remote.port = typeof r.port === "string" && /^[0-9]+$/.test(r.port) ? Number(r.port) : r.port;
  if (r.identity !== undefined && r.identity !== null && r.identity !== "") remote.identity = r.identity;
  vm.remote = remote;
  return vm;
}

export function writeVm(b: Record<string, unknown>): VmResult {
  const vm = toVm(b);
  const errors: string[] = validateVm(vm);
  if (errors.length > 0) return { status: 400, body: { error: errors.join("; ") } };
  try {
    const { doc } = inspect();
    doc.vm = vm;
    save(doc);
  } catch (e) { return { status: 422, body: { error: (e as Error).message } }; }
  return readVm();
}
