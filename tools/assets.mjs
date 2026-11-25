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

// What an icon may hold: these elements and attributes, and nothing else, so a release of the library cannot bring a
// script, a style or an event handler into the pages.
const SVG_ATTRIBUTES = ["xmlns", "viewBox", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin"];
const SHAPE_ATTRIBUTES = [
  "d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "width", "height", "points", "transform",
  "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
];
const SHAPES = ["path", "circle", "rect", "line", "polyline", "polygon", "ellipse", "g"];

function attributes(name, text, allowed) {
  const found = [];
  let rest = text.trim();
  while (rest !== "") {
    const one = /^([a-zA-Z-]+)="([^"<>]*)"\s*/.exec(rest);
    if (!one || !allowed.includes(one[1])) {
      throw new Error(`${name}.svg: attribute not allowed in \`${rest.slice(0, 40)}\``);
    }
    found.push(`${one[1]}="${one[2]}"`);
    rest = rest.slice(one[0].length);
  }
  return found;
}

// An icon as one line of SVG: the size comes from the stylesheet (\`.icon\`), the colour is \`currentColor\`, and a screen
// reader skips it (the control that holds it has the name). The width and the height of the \`<svg>\` go; those of a
// shape stay.
function inline(name) {
  const text = readFileSync(join(iconsDir, `${name}.svg`), "utf8").replace(/<!--[\s\S]*?-->/g, "").trim();
  const frame = /^<svg\b([^>]*)>([\s\S]*)<\/svg>$/.exec(text);
  if (!frame) {
    throw new Error(`${name}.svg is not a plain icon`);
  }

  const own = attributes(name, frame[1].replace(/\s+/g, " ").replace(/ (class|width|height)="[^"]*"/g, ""), SVG_ATTRIBUTES);
  let inner = "";
  let rest = frame[2].trim();
  while (rest !== "") {
    const close = /^<\/g>\s*/.exec(rest);
    const open = /^<([a-z]+)((?:\s+[a-zA-Z-]+="[^"<>]*")*)\s*(\/?)>\s*/.exec(rest);
    if (close) {
      inner += "</g>";
      rest = rest.slice(close[0].length);
    } else if (open && SHAPES.includes(open[1])) {
      const shape = attributes(name, open[2].replace(/\s+/g, " "), SHAPE_ATTRIBUTES).join(" ");
      inner += `<${open[1]}${shape === "" ? "" : ` ${shape}`}${open[3] === "/" ? "/" : ""}>`;
      rest = rest.slice(open[0].length);
    } else {
      throw new Error(`${name}.svg: element not allowed at \`${rest.slice(0, 40)}\``);
    }
  }

  return `<svg class="icon" aria-hidden="true" focusable="false" ${own.join(" ")}>${inner}</svg>`;
}

writeFileSync(
  iconsFile,
  `## The icons of Lucide (ISC) and Feather (MIT) that the pages use (vendor/lucide, with its LICENSE), as inline SVG, written
## by \`make assets\` (tools/assets.mjs). Do not edit it: change \`ICONS\` there and build again. They are markup that the
## build made, for \`<%== %>\`.

${ICONS.map((name) => `ICON_${name.toUpperCase().replaceAll("-", "_")} = (\n  ${JSON.stringify(inline(name))}\n)`).join("\n")}
`,
);

for (const [kind, { bytes }] of Object.entries(built)) {
  console.log(`${paths[kind]} ${bytes.length} bytes`);
}
