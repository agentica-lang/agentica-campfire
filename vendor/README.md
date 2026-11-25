# vendor/

Third-party files that the build reads. Nothing here runs.

## lucide/

The icons of [Lucide](https://lucide.dev) (ISC; the icons derived from Feather are MIT, both in `LICENSE`): the
`icons/` folder of the npm package `lucide-static` 1.72.0 (published 2026-11-11), copied byte for byte, and its
`LICENSE`. The tarball `https://registry.npmjs.org/lucide-static/-/lucide-static-1.72.0.tgz` has the integrity
`sha512-QhdZ60O7Zcs/e8gw40uMfEn055xZTHBZoNi0xb+/1R2dTd0v4FXS46VL6rKSwC+V92tLBiqsAbCcijy7Wy4j4w==`.

`make assets` takes only the icons that `ICONS` of `tools/assets.mjs` names and writes them as inline SVG
(`currentColor`) to `src/campfire_web/icons.agc`. To use another icon, add its name there and build again. To move
the release, replace `icons/` and `LICENSE` from a release at least two weeks old, and change the version and the
integrity above.
