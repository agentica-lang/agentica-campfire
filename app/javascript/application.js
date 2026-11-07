// The script of the pages, three parts that need nothing of each other. The boosts under the messages (boosts.js), the
// composer of a room (composer.js) and the live updates (live.js, in every page with the sidebar) are enhancements:
// the pages work without this file.
// `make assets` bundles it with esbuild into public/assets/campfire-DIGEST.js.

import { startBoosts } from "./boosts.js";
import { startComposer } from "./composer.js";
import { startLive } from "./live.js";

startBoosts();
startComposer();
startLive();
