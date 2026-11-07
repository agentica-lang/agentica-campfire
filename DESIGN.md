# Design

The visual design system of the app. `public/assets/campfire-DIGEST.css` is its one implementation, built from `app/assets/stylesheets/` by `make assets`;
change this file and the stylesheet together. One stylesheet, one script of about 18 KB minified that the room page, the edit page and the pages with the sidebar load, no web fonts, no
images: the page stays small, because the benchmark compares page throughput with a Rails Campfire.

## Principles

- Warm and quiet: paper-like neutrals, one accent (the red of a fire), no gradients.
- Light and dark follow the system (`prefers-color-scheme`); there is no switch.
- Element selectors first. Markup that `specs/` match byte for byte (links, `<h1>`, forms, the message `<div>`) takes no
  class, so it is styled by element and attribute. A class is for a part that no spec reads (`.lists`, `.scroller`,
  `.people`, `.badge`, `.quiet`, `.danger`); the composer and the search form are styled by `main.room > form` and
  `form[action="/searches"]`, since specs match their `<form>` tag.
- Fixed markup of a message (`Views.message`) is the benchmark's contract: style it, never change it. The additions are
  `data-creator-id` on the `<div>` (the author, for the side of the bubble), the Edit link in the heading, after the
  time, for the person who may change the message (its author and an administrator) and nobody else, and the boosts
  `<div>` after the presentation `<div>`, inside the frame: the benchmark reads the id, the presentation `<div>` and the
  end of the message (`</turbo-frame></div>`), none of which moves; but for those, the boosts and the clock time in
  `<time>` (the whole instant is in `datetime`, as before, and in `title`), the markup is the contract byte for byte.

## Colour tokens

All colours are custom properties on `:root`; the dark values replace them in one `@media (prefers-color-scheme: dark)`
block. A component never writes a colour.

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | `#fff` | `#161311` | page, composer |
| `--bg-side` | `#f5f0ea` | `#1d1917` | sidebar, code, inset blocks |
| `--bg-canvas` | `#f5f0ea` | `#100e0d` | behind the card of a page with no sidebar |
| `--bg-card` | `#fff` | `#1d1917` | that card |
| `--bg-field` | `#fff` | `#26211e` | inputs |
| `--hover` | 3% ink | 5% white | hover of rows and quiet buttons |
| `--text` | `#211c18` | `#f2ede7` | body text |
| `--muted` | `#645a51` | `#aca196` | times, hints, labels of groups |
| `--line` | `#e3dcd3` | `#302b27` | dividers (decoration only) |
| `--line-strong` | `#8a7e74` | `#7d7369` | borders of controls (3:1 or more) |
| `--accent` | `#b0301c` | `#c4412b` | primary button, checkbox, alert bar |
| `--accent-hover` | `#8f2515` | `#a8341f` | primary button on hover |
| `--accent-fg` | `#fff` | `#fff` | text on the accent |
| `--link` | `#b0301c` | `#ff9a85` | links and the text of `.danger` |
| `--flash-bg` | `#fdece8` | `#3a1c16` | alert background |
| `--focus` | `#1a5fd0` | `#7db0ff` | focus ring |

## Type

System font stack (`system-ui`), base 16px / 1.5. Scale (`--fs-*`): xs 0.75rem (times, badges, group labels), sm 0.875rem
(labels, hints, the sidebar links of actions), md 1rem (body, inputs), lg 1.125rem (`h2`, the room title), xl 1.5rem
(`h1`). Headings are 600 to 700 weight with line-height 1.25 and wrap anywhere: a name has no length limit that the layout
trusts. Code uses the system monospace at 0.9em. Inputs are 16px or more on a phone, so iOS does not zoom.

## Space, radius, shadow

Spacing scale (`--s-*`): 0.25, 0.5, 0.75, 1, 1.5, 2 rem. Radius: `--r-sm` 0.375rem (controls), `--r-md` 0.625rem (cards),
`--r-pill` 999px (chips, badges, boosts). One shadow, `--shadow`, for the card of a page with no sidebar. Content text is at most 44rem wide
(messages 70ch).

## Layout

- Wide: a sidebar of `clamp(14rem, 22vw, 18rem)`, sticky and full height, then the main column. Pages with no sidebar
  (first run, sign in, join, reset) are one 26rem card, centred.
- A room fills the window: header, the message list (the only part that scrolls), the composer. The list is a
  `column-reverse` flex box with one child, so the scroll starts at the newest message with no script. The window is
  `100vh` with `100dvh` after it, and every page says `interactive-widget=resizes-content` in its viewport meta: an
  Android browser then shrinks the layout when the keyboard opens, so the header and the phone bar stay on screen and
  nothing scrolls the page. (iOS Safari ignores the key and moves the page: a known gap.)
- Phone (up to 40rem): the sidebar becomes a bar. Row one is who you are and Sign out, row two is one horizontally
  scrolling row of chips (rooms, direct messages, then the actions); the group headings stay for screen readers only.
  Hover tints apply only where there is hover, so a tap leaves no stuck tint. The bar also applies to a touch screen
  turned sideways (`max-height: 30rem` and `pointer: coarse`). In a window shorter than 34rem (a phone with its
  keyboard open) the bar is one row, the chips with Sign out at their end, and "Signed in as" goes; under 24rem the
  room header and the composer are thinner. This depends on the height alone and never on the focus: a layout that
  moves when the field loses the focus moves the chip being tapped, and the tap is lost.

## Components

- **Sidebar** (`nav`): `.who`, then `.lists` (`h2` group labels in small caps, `ul#shared_rooms`, direct messages,
  `ul.actions`), then the Sign out form. A long room name wraps to two lines and ends in an ellipsis.
- **Room** (`main.room`): `header` with the `h1` (two lines at most) and, for those who may, the Settings link and the
  Sidebar link drawn as quiet buttons; `.scroller` > `.thread` with the "Older messages" and "Latest messages"
  links centred and muted; the composer form with a one-line textarea that grows to 40vh (`field-sizing`) and the Send button, with the safe-area inset below.
  The textarea has no `autofocus`: a phone would open its keyboard on every load. The script focuses it only on a
  device with a fine pointer (a mouse or a trackpad).
- **Message** (`[data-message-id]`): in a room a bubble, with a rounded corner (`--r-lg`) and a width of at most 75%
  (85% on a phone). The messages of other people sit on the left on `--bubble-other-bg`, with the name in bold, the
  clock time (`HH:MM`, UTC; the whole instant is in `datetime` and `title`) and the Edit link (extra small) in one line,
  the body below. The messages of the person who looks sit on the right in the accent colour with no name. The side is
  not in the markup (the live HTML is the same for everybody): each bubble reads `--bubble-bg`, `--bubble-fg`,
  `--bubble-meta`, `--bubble-link`, `--bubble-side` and `--bubble-name` with the other people's values as defaults, and
  the room page has one `<style>` rule setting them for `[data-creator-id="ME"]` (`Views.room`). Search results keep the
  flat list. The body wraps anywhere; `pre` and tables scroll inside the bubble.
- **Boosts** (`[id^="boosts_message_"]`, under the body): a wrapping row of pills, each the booster's name (extra small,
  muted), the text and, on the viewer's own boosts only, a `×` button that takes it away; then the "Boost" link (extra
  small, bold, the link colour of the bubble), always last (`order`), since a boost that arrives live is appended after
  it. A pill takes the colour of the text it sits in (a 35% border of `currentcolor`), so it works on both bubbles and
  on a search result. The viewer's rule sets `--boost-remove` (`Views.viewer_style`). The menu that adds one
  (`[id^="new_boost_message_"]`) is a grid of the eight reactions, `.quiet` buttons of 1.5rem, over a row with the field
  for words and its button; the page `/messages/ID/boosts/new` shows the same element in a card.
- **Buttons**: primary (accent fill) is the default; `.quiet` (outline, text colour) for secondary actions; `.danger`
  (outline in the accent) for Deactivate and Delete room. 2.5rem high; 2.75rem (44px) on a phone, for every button and the chips; 2rem
  in a dense list and the room header on a wide screen.
- **Forms**: a block label (600, sm) above a full-width field, 1px `--line-strong` border, `--r-sm`. People and members are
  a `fieldset` of checkbox rows, 2.25rem high, with the accent for the box. Hints are muted and small.
- **Flash** (`[role="alert"]`): `--flash-bg` with a 4px accent bar on the start side. The text keeps `--text`.
- **People**: a list of rows; name in bold, email muted, `.badge` pills for `administrator` and `deactivated`, the action
  button at the end. On a phone the email takes its own line before it breaks mid-word. The join link is a dashed block.

## States

- Hover: `--hover` tint on rows and links of the sidebar; the primary button darkens to `--accent-hover`.
- Focus: `:focus-visible` shows a 2px `--focus` ring with a 2px offset, on everything focusable. Fields also take the
  ring's colour as their border.
- Disabled: 50% opacity and `not-allowed`. (No page has a disabled control yet.)
- Empty: `.empty` centred and muted ("No messages here yet.", "No messages match.").

## Script

`public/assets/campfire-DIGEST.js` is the only script, linked by the room page (`Views.room`), the page that edits a
message (`Views.edit_message`) and every page with the sidebar (`live_layout`), and the pages work without it. Its first
part is the boosts (the "Boost" link opens the reactions under the message, a post goes with `fetch` asking for a Turbo
Stream, Esc or Cancel closes the menu, and a refusal is sent again as a plain post, as the composer's is). Its last
part keeps them live (`docs/cable.md`, "The pages"); a room with something new is `nav li.unread`, bold with a dot. The
composer works without it (a plain post and a redirect), and has the keys of the composer and of the edit form. It sends the message with `fetch`, asking for the Turbo Stream that
`POST /rooms/ID/messages` already answers, appends the message to the list, clears the box, gives the form a new
`client_message_id`, scrolls to the newest message and keeps the focus in the box, so a phone keeps its keyboard open
(Send takes no focus on `pointerdown`). A refusal (any non-2xx answer) is sent again as a plain post, so the page of
the refusal shows its reason; a lost connection leaves the text and shows a line. A page that does not end at the newest
message (`?before=`, `/rooms/ID/@MESSAGE`) uses the plain post, since the latest message does not belong at the end of it. What was typed while the post
was in flight stays in the box; only the text that was sent is cleared. The "Not sent" line is an empty
`<p aria-live="polite">` in the page that the script fills, so a screen reader announces it. The `client_message_id`
is new after each send, but the server does not use it to drop a repeat (as in Rails: `docs/rooms.md`), so a retry
after an answer that was lost can store the message twice. Keys, as in Rails Campfire: in the box, Enter sends and
Shift+Enter is a new line, Ctrl or Cmd+Enter sends, and an input method that is choosing a character (`isComposing`)
sends nothing; on a touch screen (`(pointer: coarse)`, the main pointer, not whether the device can be touched) Enter
stays a new line. A blank box sends nothing and shows no validation bubble. On the edit page, Ctrl or Cmd+Enter saves
and Esc goes to the room, discarding the change (it follows the `data-cancel` link). `tools/keys_check.js` checks the
keys in a real browser; run it by hand after a change to the script. No framework, no CDN.

The room page has three more parts, all progressive. **Scroll paging** (`message_pager.js`): the "Older messages" link
loads the 40 messages before the first one when it comes within 300px of the top of the list (`GET
/rooms/ID/messages?before=ID`), and on a page at a cursor the "Latest messages" link loads the 40 after the last one
(`?after=ID`) the same way near the bottom; a 204 takes the link away, and at the newest message the page is the latest
one (a message that is sent or heard is appended again, and the live part fetches the room's latest page once, for what was
created while the pager walked down). An answer that is a redirect (a signed-out session), a page with no message that the
list lacks, or a refusal is not inserted; a lost connection, a 5xx or a 429 is tried again 3 times with a growing pause (a
`Retry-After` is honoured, up to 30 s), and after that the pager sleeps until the browser is online again or the reader
scrolls with the link in reach; the link stays all the while. A 204 is not the end at once: the room answers 204 for a message it does not have (one that was
deleted), so the pager asks again from the neighbour of the cursor, and only a page with no news ends the walk. The live
catch-up decides what the fetched page covers by position, not by id (an id does not follow time in a database that Rails
seeded), and a fetched page with nothing in common with the list (40 or more messages came while the socket was away)
becomes the list, with a link to the messages before it. The links stay in the markup as the way of a browser without the
script, and the server markup of a message is not touched. **Scroll keeping** (`scroll_keeper.js`): the list is a
column-reverse box, so the scroll starts at the newest message with no script and older messages added above never move
it. For everything else that changes the thread (a message heard or sent, an edit, a boost, a link that goes away) the script remembers one
message of the view and puts it back where it was, with the browser's own anchoring off (`overflow-anchor`); a reader
within 100px of the newest message of a latest page stays at it. **Local time** (`local_time.js`): each
`<time datetime>` is written in the viewer's zone and language (the clock, `10:35 PM`; with the date, `Nov 6, 2026, 10:35
PM`, when it is not today) with the whole date and time as the title; the server text is the UTC clock, the fallback.
`tools/room_check.js` checks the three in a real browser, by hand.

## Accessibility

- Contrast: text 4.5:1 or more on its background, in both themes (body about 15:1, muted 5.9:1 or more, accent buttons with
  white text 5.1:1 or more, links 5.6:1 or more); borders of controls and the focus ring 3:1 or more. Check a new colour
  pair before adding it.
- Landmarks: `nav` has a label, `main` has `id="main"`, and a "Skip to the page" link is the first thing in the sidebar and
  shows on focus. Fields have a real `label` (hidden by `.sr-only` for the composer and the search box, which have a
  placeholder too). Alerts use `role="alert"`.
- Targets: 2.5rem or more for controls on a wide screen (2rem only in dense rows (People) and the room header
  (Settings)); on a phone every button, chip and checkbox row is 2.75rem (44px) or more. Text links in the page body
  ("Older messages", "Latest messages", the join link and the like) are out of scope: they keep the size of their text.
- Motion: the only transition is a 0.12s background change, and only with `prefers-reduced-motion: no-preference`.
- Zoom: sizes are in `rem`; nothing is fixed in pixels but borders. The layout holds at 320px with no sideways page scroll
  (only the chip row scrolls).
- Colour is never the only signal: the alert has a bar, `deactivated` and `administrator` are words, links keep their
  underline outside the sidebar.

## Changing the design

1. Look at it in a browser (sign in, a room with long messages, People) at 1280px and 390px, light and dark, and
   in a room at 390x450 (a phone with its keyboard open).
2. Keep to the tokens; add a token before adding a literal.
3. Run `make assets` (see AGENTS.md, "Assets"): it names the stylesheet by its digest.
4. Keep markup changes small and check `specs/` for what they match.

## Known gaps

- Tab reaches "Older messages" and scrolls the thread to its top, since the link is the first thing in the scroller.
- The skip link is a dead anchor on `/users/me/sidebar`, which has a `nav` and no `main`.
- The message time is the raw ISO instant, which the specs pin; there is no avatar, author grouping or active-room mark.
