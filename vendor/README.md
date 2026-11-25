# vendor/

Third-party files that the build reads. Nothing here runs.

## lucide/

The icons of [Lucide](https://lucide.dev) (ISC; the icons derived from Feather are MIT, both in `LICENSE`): the
`icons/` folder of the npm package `lucide-static` 1.72.0 (published 2026-11-11), copied byte for byte, and its
`LICENSE`. The tarball `https://registry.npmjs.org/lucide-static/-/lucide-static-1.72.0.tgz` has the integrity
`sha512-QhdZ60O7Zcs/e8gw40uMfEn055xZTHBZoNi0xb+/1R2dTd0v4FXS46VL6rKSwC+V92tLBiqsAbCcijy7Wy4j4w==`.

`make assets` takes only the icons that `ICONS` of `tools/assets.mjs` names and writes them as inline SVG
(`currentColor`) to `src/campfire_web/icons.agc`; it refuses an element or an attribute outside a short list of SVG
shapes. To use another icon, add its name there and build again.

To move the release, use one at least two weeks old, and work in an empty folder:

1. `npm pack lucide-static@X.Y.Z`, and unpack the tarball there (do not install or run anything from it).
2. Compare `openssl dgst -sha512 -binary lucide-static-X.Y.Z.tgz | base64` with `npm view lucide-static@X.Y.Z
   dist.integrity`.
3. Replace `icons/` and `LICENSE` here with those of the package, check with `diff -r`, and change the version, the
   date and the integrity above.
