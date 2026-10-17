#!/usr/bin/env node

import { readFileSync } from "node:fs";

const src = readFileSync(process.argv[2], "utf8");

const field = (block, name) => {
  const m = block.match(new RegExp(`\\.${name} = hex\\("(#[0-9A-Fa-f]{6})"\\)`));
  return m ? m[1] : null;
};

const roles = ["primary", "secondary", "tertiary", "error", "surface"];

const names = [...src.matchAll(/\.name = "([^"]+)"/g)].map((m) => m.index);
const palettes = [];

for (let i = 0; i < names.length; i++) {
  const start = names[i];
  const end = i + 1 < names.length ? names[i + 1] : src.length;
  const block = src.slice(start, end);
  const nameMatch = block.match(/\.name = "([^"]+)"/);
  const name = nameMatch[1];

  const darkIdx = block.indexOf(".dark");
  const lightIdx = block.indexOf(".light");
  const darkBlock = block.slice(darkIdx, lightIdx);
  const lightBlock = block.slice(lightIdx);

  const mode = (b) => roles.map((r) => field(b, r));
  palettes.push({ name, dark: mode(darkBlock), light: mode(lightBlock) });
}

const esc = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

let out = "return {\n";
for (const p of palettes) {
  out += `  {\n    name = "${esc(p.name)}",\n`;
  out += `    dark = { ${p.dark.map((c) => `"${c}"`).join(", ")} },\n`;
  out += `    light = { ${p.light.map((c) => `"${c}"`).join(", ")} },\n`;
  out += `  },\n`;
}
out += "}\n";

process.stdout.write(out);
