// `make assets`: builds the stylesheet (Dart Sass) and the script (esbuild) of the app, names each one by the first 16
// hex digits of the SHA-256 of its bytes (campfire-DIGEST.css and .js, the rule that specs/assets.feature checks), writes
// them to public/assets/, removes the files of earlier builds, and writes src/campfire_web/asset_names.agc, the one file
// that holds the names, and src/campfire_web/icons.agc, the icons of vendor/lucide that the pages use. The two logos of
// app/assets/images/ (WebP, already cropped and sized) are named the same way.
// The output is the same bytes for the same sources, so CI runs this and fails when `git diff` shows a change.

import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as esbuild from "esbuild";
import * as sass from "sass";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "public/assets");
const images = join(root, "app/assets/images");
const names = join(root, "src/campfire_web/asset_names.agc");
const iconsDir = join(root, "vendor/lucide/icons");
const iconsFile = join(root, "src/campfire_web/icons.agc");

// The icons of Lucide (vendor/lucide) that the app uses: each is inlined in the pages as an SVG that takes the colour
// of its text.
const ICONS = ["paperclip", "x"];

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

const built = {
  css: { bytes: Buffer.from(css), name: "campfire", ext: "css" },
  js: { bytes: Buffer.from(script.outputFiles[0].contents), name: "campfire", ext: "js" },
  logo: { bytes: readFileSync(join(images, "logo.webp")), name: "logo", ext: "webp" },
  logoDark: { bytes: readFileSync(join(images, "logo-dark.webp")), name: "logo-dark", ext: "webp" },
};

mkdirSync(out, { recursive: true });

for (const old of readdirSync(out)) {
  if (/^(campfire|logo|logo-dark)-[0-9a-f]{16}\.(css|js|webp)(\.gz)?$/.test(old)) {
    rmSync(join(out, old));
  }
}

const paths = {};
for (const [kind, { bytes, name, ext }] of Object.entries(built)) {
  const digest = createHash("sha256").update(bytes).digest("hex").slice(0, 16);
  const file = `${name}-${digest}.${ext}`;
  writeFileSync(join(out, file), bytes);
  paths[kind] = `/assets/${file}`;
}

writeFileSync(
  names,
  `## The names of the built stylesheet, script and logos, written by \`make assets\` (tools/assets.mjs). Do not edit it: build
## again. The name has the first 16 hex digits of the SHA-256 of the file, which \`specs/assets.feature\` checks.

STYLESHEET = "${paths.css}"
SCRIPT = "${paths.js}"
LOGO = "${paths.logo}"
LOGO_DARK = "${paths.logoDark}"
`,
);

// An icon as one line of SVG: the size comes from the stylesheet (`.icon`), the colour is `currentColor`, and a screen
// reader skips it (the control that holds it has the name).
function inline(name) {
  const text = readFileSync(join(iconsDir, `${name}.svg`), "utf8")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/\s+/g, " ")
    .replace(/> </g, "><")
    .replace(/ (width|height)="[^"]*"/g, "")
    .replace(/ class="[^"]*"/, ' class="icon" aria-hidden="true" focusable="false"')
    .replace(/ \/>/g, "/>")
    .replace(/"\s*>/, '">')
    .trim();
  if (!text.startsWith("<svg") || !text.endsWith("</svg>") || text.includes("<script")) {
    throw new Error(`${name}.svg is not a plain icon`);
  }
  return text;
}

writeFileSync(
  iconsFile,
  `## The icons of Lucide (vendor/lucide) that the pages use, as inline SVG, written by \`make assets\` (tools/assets.mjs).
## Do not edit it: change \`ICONS\` there and build again. They are markup that the build made, for \`<%== %>\`.

${ICONS.map((name) => `ICON_${name.toUpperCase().replaceAll("-", "_")} = (\n  ${JSON.stringify(inline(name))}\n)`).join("\n")}
`,
);

for (const [kind, { bytes }] of Object.entries(built)) {
  console.log(`${paths[kind]} ${bytes.length} bytes`);
}
