import fs from "node:fs";

const counts = new Map();
const read = fs.readFileSync;
const write = fs.writeFileSync;
fs.readFileSync = function (p, ...rest) {
  const key = String(p);
  counts.set(key, (counts.get(key) || 0) + 1);
  return read.call(this, p, ...rest);
};
process.on("exit", () => {
  const lines = [...counts].sort(([a], [b]) => (a < b ? -1 : 1)).map(([p, n]) => `${n}\t${p}`);
  write.call(fs, process.env.FUNNEL_READ_LOG, lines.join("\n") + "\n");
});
