import dns from "node:dns";
import { appendFileSync } from "node:fs";

const real = dns.lookup;
let calls = 0;
dns.lookup = function (host, options, cb) {
  if (typeof options === "function") { cb = options; options = {}; }
  if (host !== "rebind.test") return real.call(this, host, options, cb);
  appendFileSync(process.env.REBIND_LOG, "lookup\n");
  const address = ++calls === 1 ? "192.0.2.1" : "127.0.0.1";
  if (options && options.all) return process.nextTick(cb, null, [{ address, family: 4 }]);
  return process.nextTick(cb, null, address, 4);
};
