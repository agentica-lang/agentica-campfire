// `make assets`: builds the stylesheet (Dart Sass) and the script (esbuild) of the app, names each one by the first 16
// hex digits of the SHA-256 of its bytes (campfire-DIGEST.css and .js, the rule that specs/assets.feature checks), writes
// them to public/assets/, removes the files of earlier builds, and writes src/campfire_web/asset_names.agc, the one file
// that holds the two names. The output is the same bytes for the same sources, so CI runs this and fails when
// `git diff` shows a change.

import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";
import * as sass from "sass";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "public/assets");
const names = join(root, "src/campfire_web/asset_names.agc");

const css = sass.compile(join(root, "app/assets/stylesheets/application.scss"), { style: "compressed" }).css;

const script = await esbuild.build({
  entryPoints: [join(root, "app/javascript/application.js")],
  bundle: true,
  minify: true,
  format: "iife",
  target: "es2017",
  legalComments: "none",
  write: false,
  logLevel: "warning",
});

const built = { css: Buffer.from(css), js: Buffer.from(script.outputFiles[0].contents) };

mkdirSync(out, { recursive: true });

for (const old of readdirSync(out)) {
  if (/^campfire-[0-9a-f]{16}\.(css|js)(\.gz)?$/.test(old)) {
    rmSync(join(out, old));
  }
}

const paths = {};
for (const [kind, bytes] of Object.entries(built)) {
  const digest = createHash("sha256").update(bytes).digest("hex").slice(0, 16);
  const file = `campfire-${digest}.${kind}`;
  writeFileSync(join(out, file), bytes);
  paths[kind] = `/assets/${file}`;
}

writeFileSync(
  names,
  `## The names of the built stylesheet and script, written by \`make assets\` (tools/assets.mjs). Do not edit it: build
## again. The name has the first 16 hex digits of the SHA-256 of the file, which \`specs/assets.feature\` checks.

STYLESHEET = "${paths.css}"
SCRIPT = "${paths.js}"
`,
);

console.log(`${paths.css} ${built.css.length} bytes`);
console.log(`${paths.js} ${built.js.length} bytes`);
