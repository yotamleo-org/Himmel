import { lstatSync } from "node:fs";
import { join } from "node:path";

export function lockdownEnabled(root: string): boolean {
  try { lstatSync(join(root, "lockdown")); return true; }
  catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return false; throw e; }
}
