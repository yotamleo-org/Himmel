// Test-only preload: directory listings omit the file names in HIDE_FROM_LISTING
// (separated by "|"), as if the file appeared after the listing was taken.
// Used with: NODE_OPTIONS="--import <this file>" node synthesize-stubs.mjs ...
import fs from "node:fs";

const hidden = new Set((process.env.HIDE_FROM_LISTING || "").split("|").filter(Boolean));
const listDir = fs.readdirSync;
fs.readdirSync = (dir, options) =>
  listDir(dir, options).filter((e) => !hidden.has(typeof e === "string" ? e : e.name));
