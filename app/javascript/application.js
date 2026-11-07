// The script of the pages, parts that need nothing of each other. The boosts under the messages (boosts.js), the
// composer of a room (composer.js), the live updates (live.js, in every page with the sidebar) and, on a room page, the
// scroll (scroll_keeper.js keeps the reader's place, message_pager.js loads the pages above and below) and the local
// time of the messages (local_time.js) are enhancements: the pages work without this file.
// `make assets` bundles it with esbuild into public/assets/campfire-DIGEST.js.

import { startBoosts } from "./boosts.js";
import { startComposer } from "./composer.js";
import { startLive } from "./live.js";
import { startLocalTime } from "./local_time.js";
import { startMessagePager } from "./message_pager.js";
import { roomPage } from "./room_page.js";
import { startScrollKeeper } from "./scroll_keeper.js";

startLocalTime();
startBoosts();
startComposer();
startLive();

var page = roomPage();
if (page) {
  // The keeper first: it watches the list before the pager changes it.
  startScrollKeeper(page);
  startMessagePager(page);
}
