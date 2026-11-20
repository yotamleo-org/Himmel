import fs from "node:fs";

const hidden = new Set((process.env.HIDE_FROM_LISTING || "").split("|").filter(Boolean));
const listDir = fs.readdirSync;
fs.readdirSync = (dir, options) =>
  listDir(dir, options).filter((e) => !hidden.has(typeof e === "string" ? e : e.name));
