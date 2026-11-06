// The script of the pages, two parts that need nothing of each other. The composer of a room (composer.js) and the
// live updates (live.js, in every page with the sidebar) are enhancements: the pages work without this file.
// `make assets` bundles it with esbuild into public/assets/campfire-DIGEST.js.

import { startComposer } from "./composer.js";
import { startLive } from "./live.js";

startComposer();
startLive();
