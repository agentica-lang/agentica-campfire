## The pages, as EAG templates. A template with `<%@ escape &Bond.escape %>` escapes every `<%= %>`, so a value goes
## into the page as text; `<%== %>` is the way out, only for markup that this program wrote itself.

import EAG from "std/eag"
import Bond from "pkg/bond/bond"
import Accounts from "../campfire/accounts"
import Autolink from "../campfire/autolink"
import Boosts from "../campfire/boosts"
import Bots from "../campfire/bots"
import Profiles from "../campfire/profiles"
import Rails from "../campfire/repo/rails"
import Rooms from "../campfire/rooms"
import Searches from "../campfire/searches"
import Routes from "routes"

# The name of the app, in the title and the heading.
NAME = "Campfire"

# The ids of the lists of the sidebar that a live change appends to (`shared_rooms` is the one that the page has always
# had).
SHARED_ROOMS_ID = "shared_rooms"
DIRECT_ROOMS_ID = "direct_rooms"

# A quick reaction of the boost menu: the emoji that is posted and the name that a screen reader reads.
struct Reaction
  emoji: String
  title: String
end

## A bot of the list with the rooms it is in, but the direct ones: the rooms that its curl lines post to.
export struct BotRooms
  bot: Bots.Bot
  rooms: List[Rooms.Room]
end

## The two streams of a new message, the broadcast (`message_stream` without the controls) and the answer to the person
## who wrote it (with them), byte for byte, with the message written once.
export struct MessageStreams
  broadcast: String
  own: String
end

## What the form of a room page needs: a `note` that says why the last message was refused ("" shows none), the text
## to put back in the field (`draft`), and the id that this form sends with its message (`message_id`).
export struct Composer
  note: String
  draft: String
  message_id: String
end

## The page around `content`, which is raw HTML that the caller made safe (another template, never a value of a
## client): only the templates of this file call it. `title` is text, and is escaped.
export def layout(title: String, content: String) -> String
  <<~EAG
    <%@ escape &Bond.escape %>
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
      <meta name="color-scheme" content="light dark">
      <link rel="icon" href="data:,">
      <title><%= title %></title>
      <link rel="stylesheet" href="<%= Routes.STYLESHEET %>">
    </head>
    <body>
    <%== content.strip %>
    </body>
    </html>
  EAG
end

## The column at the side of every page of a person who is signed in: who they are, their rooms (the direct messages
## apart, named after the other people) and the ways to make a room and to sign out. `can_create` is false for a member
## when the account lets only administrators make a shared room: the two links to those forms are then left out.
## `unread` is the ids of the rooms with news, which are marked. It is raw HTML that this file made, for the pages
## below to put in.
export def sidebar(user_name: String, rooms: List[Rooms.Room], can_create: Bool, unread: List[Int]) -> String
  shared = rooms.select do |room| room.room_type != Rooms.DIRECT end
  direct = rooms.select do |room| room.room_type == Rooms.DIRECT end
  <<~EAG
    <%@ escape &Bond.escape %>
    <nav aria-label="Rooms">
      <a class="skip" href="#main">Skip to the page</a>
      <p class="who">Signed in as <%= user_name %></p>
      <div class="lists">
        <h2>Rooms</h2>
        <ul id="<%= SHARED_ROOMS_ID %>">
    <% for room in shared %>
          <%== room_entry(room, unread.include?(room.id)) %>
    <% end %>
        </ul>
    <% if not direct.empty? %>
        <h2>Direct messages</h2>
        <ul id="<%= DIRECT_ROOMS_ID %>">
    <% for room in direct %>
          <%== room_entry(room, unread.include?(room.id)) %>
    <% end %>
        </ul>
    <% end %>
        <ul class="actions" aria-label="Actions">
    <% if can_create %>
          <li><a href="<%= Routes.ROOM_NEW %>">New room</a></li>
          <li><a href="<%= Routes.CLOSED_ROOM_NEW %>">New closed room</a></li>
    <% end %>
          <li><a href="<%= Routes.DIRECT_ROOM_NEW %>">New direct message</a></li>
          <li><a href="<%= Routes.SEARCHES %>">Search</a></li>
          <li><a href="<%= Routes.USERS %>">People</a></li>
          <li><a href="<%= Routes.profile_path() %>">Profile</a></li>
          <li><a href="<%= Routes.ACCOUNT_EDIT %>">Account</a></li>
        </ul>
      </div>
      <form method="post" action="<%= Routes.SIGN_OUT %>">
        <button type="submit" class="quiet">Sign out</button>
      </form>
    </nav>
  EAG
end

## The account settings page (`accounts/edit.html.erb`): the name of the account and, for an administrator, a form that
## renames it (`name` is the box, `note` says why a save was refused) and a button that switches who may create rooms
## (`restricted`, the setting of the account: only administrators, or everybody), then the active people with the administrators
## first, as Rails lists them. An administrator can make each person but themselves an administrator or a member, and
## remove them (deactivate, which an administrator undoes on the people page). Plain form posts with the `_method` of
## Rails' forms, so they work without a script.
export def account(
  sidebar: String,
  name: String,
  people: List[Accounts.Person],
  me: Int,
  admin: Bool,
  restricted: Bool,
  note: String,
) -> String
  administrators = people.select do |one| one.role == Rooms.ADMINISTRATOR_ROLE_NAME end
  members = people.select do |one| one.role != Rooms.ADMINISTRATOR_ROLE_NAME end
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Account settings</h1>
    <% if not note.empty? %>
      <p role="alert"><%= note %></p>
    <% end %>
    <% if admin %>
      <form method="post" action="<%= Routes.ACCOUNT %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
        <p>
          <label>Name of the account
            <input name="account[name]" type="text" value="<%= name %>" maxlength="<%= Accounts.MAX_NAME_LENGTH %>"
              required></label>
        </p>
        <p><button type="submit">Save</button></p>
      </form>
      <form method="post" action="<%= Routes.ACCOUNT %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
        <input name="account[settings][restrict_room_creation_to_administrators]" type="hidden" value="<%= not restricted %>">
        <p>
    <% if restricted %>
          Who can create rooms: <strong>administrators only</strong>
          <button type="submit" class="quiet">Let everybody create rooms</button>
    <% else %>
          Who can create rooms: <strong>everybody</strong>
          <button type="submit" class="quiet">Only administrators can create rooms</button>
    <% end %>
        </p>
      </form>
    <% else %>
      <h2><%= name %></h2>
    <% end %>
      <h2>People</h2>
      <ul class="people">
    <% for one in administrators %>
        <%== account_person(one, me, admin).strip %>
    <% end %>
    <% for one in members %>
        <%== account_person(one, me, admin).strip %>
    <% end %>
      </ul>
      <p><a href="<%= Routes.USERS %>">People and the join link</a></p>
    <% if admin %>
      <p><a href="<%= Routes.BOTS %>">Chat bots</a></p>
    <% end %>
    </main>
  EAG
  live_layout("Account settings", body)
end

## The chat bots page (`accounts/bots/index.html.erb`, for administrators): each active bot with its key, a link to its
## edit page, and a curl line that posts to each room it is in (`origin` is where the app is: `BotMessagesWeb.origin`),
## and the link that adds one. The key is the secret of the bot, so the page is kept out of caches. Rails' second line,
## for an attachment, waits for the attachments.
export def bots(sidebar: String, list: List[BotRooms], origin: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Chat bots</h1>
      <p>Each chat bot has a key. A new key stops the old one from working.</p>
      <p><a href="<%= Routes.BOT_NEW %>">Add a chat bot</a></p>
    <% if list.empty? %>
      <p>There are no chat bots yet.</p>
    <% else %>
      <ul class="people">
    <% for entry in list %>
        <li>
          <span class="name"><%= entry.bot.name %></span>
          <code class="meta"><%= entry.bot.key %></code>
          <a href="<%= Routes.bot_edit_path(entry.bot.id) %>">Edit<span class="sr-only"> <%= entry.bot.name %></span></a>
    <% for room in entry.rooms %>
          <span class="hint">Post to <%= room.name %></span>
          <code class="meta">curl -d 'Hello!' <%= origin %><%= Routes.bot_messages_path(room.id, entry.bot.key) %></code>
    <% end %>
        </li>
    <% end %>
      </ul>
    <% end %>
      <p><a href="<%= Routes.ACCOUNT_EDIT %>">Back to the account</a></p>
    </main>
  EAG
  live_layout("Chat bots", body)
end

## The form of a new chat bot (`bot` is `none`) or the page that edits one: the name (`name` is the box, `note` says why
## a save was refused), and for an existing bot its key, a button that makes a new key and one that removes the bot,
## each after a question. The webhook URL and the avatar of Rails' form are left out until the app can use them.
export def bot_form(sidebar: String, bot: Optional[Bots.Bot], name: String, note: String) -> String
  title = "New chat bot"
  action = Routes.BOTS
  if bot.some?
    title = "Edit chat bot"
    action = Routes.bot_path(bot.unwrap!.id)
  end

  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1><%= title %></h1>
    <% if not note.empty? %>
      <p role="alert"><%= note %></p>
    <% end %>
      <form method="post" action="<%= action %>">
    <% if bot.some? %>
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
    <% end %>
        <p>
          <label>Name of the bot
            <input name="user[name]" type="text" value="<%= name %>" maxlength="<%= Bots.MAX_NAME_LENGTH %>" required
              autofocus></label>
        </p>
        <p><button type="submit">Save</button></p>
      </form>
    <% if bot.some? %>
      <p>Key: <code><%= bot.unwrap!.key %></code></p>
      <form method="post" action="<%= Routes.bot_key_path(bot.unwrap!.id) %>"
        onsubmit="return confirm('Are you sure you want to change the bot key? All usage of this bot must be updated.')">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PUT %>">
        <p><button type="submit" class="danger">Generate a new key</button></p>
      </form>
      <form method="post" action="<%= action %>"
        onsubmit="return confirm('Are you sure you want to remove this bot from the account? This cannot be undone.')">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
        <p><button type="submit" class="danger">Remove bot</button></p>
      </form>
    <% end %>
      <p><a href="<%= Routes.BOTS %>">Back to the chat bots</a></p>
    </main>
  EAG
  live_layout(title, body)
end

## The sidebar alone as a document, for `GET /users/me/sidebar`. `sources` is the markup of the live streams that the
## sidebar listens to (`CableWeb.sidebar_sources`), written before it as Rails writes its `turbo_stream_from`.
export def sidebar_page(sidebar: String, sources: String) -> String = layout("Rooms", sources + "\n" + sidebar)

## The entry of a room in the sidebar. A live change finds it by its id.
export def room_item(room: Rooms.Room) -> String = room_entry(room, false)

## The entry of a room, marked when the person has it unread: a class for the style and a word for a screen reader.
## A room that is read has the markup that it always had.
export def room_entry(room: Rooms.Room, unread: Bool) -> String
  if unread
    return <<~EAG.strip
      <%@ escape &Bond.escape %>
      <li id="<%= room_item_id(room) %>" class="unread"><a href="<%= Routes.room_path(room.id) %>"><%= room.name %><span class="sr-only"> (unread)</span></a></li>
    EAG
  end

  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <li id="<%= room_item_id(room) %>"><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
  EAG
end

## The Turbo Stream that adds a room to the list of its kind in the sidebar: the direct messages, or the rooms.
export def room_added_stream(room: Rooms.Room) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="append" target="<%= list_id(room) %>"><template><%== room_item(room) %></template></turbo-stream>
  EAG
end

## The Turbo Stream that shows the new name of a room in the sidebar.
export def room_renamed_stream(room: Rooms.Room) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="replace" target="<%= room_item_id(room) %>"><template><%== room_item(room) %></template></turbo-stream>
  EAG
end

## The Turbo Stream that takes a room out of the sidebar of the people who were in it.
export def room_removed_stream(room: Rooms.Room) -> String
  "<turbo-stream action=\"remove\" target=\"#{room_item_id(room)}\"><template></template></turbo-stream>"
end

## The Turbo Stream that replaces the room page, for the people who are looking at a room that was deleted: the name of
## the room as text, and the way home. Its `<main>` has no composer, so there is nothing to post to a room that is gone.
export def room_gone_stream(room: Rooms.Room) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="replace" target="main"><template><main id="main"><h1><%= room.name %></h1><p role="status">This room was deleted.</p><p><a href="<%= Routes.HOME %>">Back to the home page</a></p></main></template></turbo-stream>
  EAG
end

## The home page of the person who is signed in, around their `sidebar`.
export def home(sidebar: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1><%= NAME %></h1>
      <p class="lead">Group chat, written in Agentica.</p>
    </main>
  EAG
  live_layout(NAME, body)
end

## The form that makes an open room. `name` fills the field again after a refusal, and `message` says why ("" shows
## none).
export def new_room(sidebar: String, name: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>New room</h1>
      <p>Everyone on the account will be in it.</p>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.ROOMS %>">
        <p>
          <label>Name
            <input name="name" type="text" value="<%= name %>" maxlength="<%= Rooms.MAX_NAME_LENGTH %>"
              required autofocus></label>
        </p>
        <p><button type="submit">Make the room</button></p>
      </form>
    </main>
  EAG
  live_layout("New room", body)
end

## The people to pick, as checkboxes named `member` with their ids as values: the ones whose id is in `chosen` come
## checked. It is raw HTML that this file made, for the forms below to put in.
export def member_picker(people: List[Rooms.Person], chosen: List[Int]) -> String
  <<~EAG
    <%@ escape &Bond.escape %>
    <fieldset>
      <legend>People</legend>
    <% for person in people %>
    <% if chosen.include?(person.id) %>
      <p><label><input type="checkbox" name="member" value="<%= person.id %>" checked> <%= person.name %></label></p>
    <% else %>
      <p><label><input type="checkbox" name="member" value="<%= person.id %>"> <%= person.name %></label></p>
    <% end %>
    <% end %>
    </fieldset>
  EAG
end

## The form that makes a closed room: the people to offer and which of them to show checked, with `name` and `message`
## as in `new_room`. The person who makes it is always in it, so it is not among `people`.
export def new_closed_room(
  sidebar: String,
  name: String,
  people: List[Rooms.Person],
  chosen: List[Int],
  message: String,
) -> String
  picker = member_picker(people, chosen)
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>New closed room</h1>
      <p>Only you and the people you pick will be in it.</p>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.CLOSED_ROOMS %>">
        <p>
          <label>Name
            <input name="name" type="text" value="<%= name %>" maxlength="<%= Rooms.MAX_NAME_LENGTH %>"
              required autofocus></label>
        </p>
        <%== picker.strip %>
        <p><button type="submit">Make the room</button></p>
      </form>
    </main>
  EAG
  live_layout("New closed room", body)
end

## The form that starts a direct message with the people that are picked. `message` says why the last try was refused
## ("" shows none).
export def new_direct_room(sidebar: String, people: List[Rooms.Person], chosen: List[Int], message: String) -> String
  picker = member_picker(people, chosen)
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>New direct message</h1>
      <p>Pick the people to write to. If you wrote to exactly them before, that conversation opens.</p>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.DIRECT_ROOMS %>">
        <%== picker.strip %>
        <p><button type="submit">Start</button></p>
      </form>
    </main>
  EAG
  live_layout("New direct message", body)
end

## The settings of an open or a closed room, drawn as the form of `kind` (`Routes.SETTINGS_OPEN` or `SETTINGS_CLOSED`),
## which is also what the room is after it is saved: a link switches the form to the other kind (Rails' toggle between
## "Everyone" and "only some"). The closed form has its name and who is in it (`chosen` of `people`, the others than the
## person who is looking, who stays); it sends the ids of the people who were in the room when it was drawn (`was`), so
## that saving it takes out only those that it unchecked, not someone who was put in after the page was drawn. The open
## form has the name alone, since everyone is in. `name` and `message` fill the form again after a refusal.
export def room_settings(
  sidebar: String,
  room: Rooms.Room,
  kind: String,
  name: String,
  people: List[Rooms.Person],
  chosen: List[Int],
  was: List[Int],
  message: String,
) -> String
  picker = member_picker(people, chosen)
  open = kind == Routes.SETTINGS_OPEN
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Settings of <%= room.name %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.room_settings_path(room.id) %>">
        <input name="type" type="hidden" value="<%= kind %>">
        <p>
          <label>Name
            <input name="name" type="text" value="<%= name %>" maxlength="<%= Rooms.MAX_NAME_LENGTH %>"
              required autofocus></label>
        </p>
    <% if open %>
        <p>Everyone on the account is in this room.</p>
    <% else %>
        <%== picker.strip %>
    <% for person in people %>
    <% if was.include?(person.id) %>
        <input name="was" type="hidden" value="<%= person.id %>">
    <% end %>
    <% end %>
    <% end %>
        <p><button type="submit">Save</button></p>
      </form>
    <% if open %>
      <p><a href="<%= Routes.room_settings_kind_path(room.id, Routes.SETTINGS_CLOSED) %>">Give only some access to this room</a></p>
    <% else %>
      <p><a href="<%= Routes.room_settings_kind_path(room.id, Routes.SETTINGS_OPEN) %>">Give everyone access to this room</a></p>
    <% end %>
      <%== delete_form(room).strip %>
      <p><a href="<%= Routes.room_path(room.id) %>">Back to the room</a></p>
    </main>
  EAG
  live_layout("Settings of #{room.name}", body)
end

## The page where a person chooses whether a room is shown in their sidebar or hidden from it: a radio for each of the
## `levels` that the room offers (none for a direct room, which stays in the sidebar), the hidden one checked when
## `hidden`, and a plain form post with the `_method` field of Rails' forms, so it works without a script. `message` says
## why a save was refused.
export def involvement(
  sidebar: String,
  room: Rooms.Room,
  levels: List[String],
  hidden: Bool,
  message: String,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Sidebar for <%= room.name %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
    <% if levels.empty? %>
      <p>A direct message always stays in the sidebar.</p>
    <% else %>
      <form method="post" action="<%= Routes.room_involvement_path(room.id) %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PUT %>">
    <% for level in levels %>
        <p>
    <% if Rooms.hidden?(level) == hidden %>
          <label><input name="involvement" type="radio" value="<%= level %>" checked>
            <%= sidebar_choice(level) %></label>
    <% else %>
          <label><input name="involvement" type="radio" value="<%= level %>">
            <%= sidebar_choice(level) %></label>
    <% end %>
        </p>
    <% end %>
        <p><button type="submit">Save</button></p>
      </form>
    <% end %>
      <p><a href="<%= Routes.room_path(room.id) %>">Back to the room</a></p>
    </main>
  EAG
  live_layout("Sidebar for #{room.name}", body)
end

## The form that deletes a room (the button of the settings page, as `button_to_delete_room` is in Rails). It is a plain
## form post with the `_method` field that Rails' forms send, so it works without a script; the `onsubmit` asks first
## and a script-less browser skips the question, as the form of Rails does without Turbo.
export def delete_form(room: Rooms.Room) -> String
  <<~EAG
    <%@ escape &Bond.escape %>
    <form method="post" action="<%= Routes.room_path(room.id) %>"
      onsubmit="return confirm('Are you sure you want to delete this room and all messages in it? This can’t be undone.')">
      <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
      <p><button type="submit" class="danger">Delete room</button></p>
    </form>
  EAG
end

## The id of the element that holds the messages of a room (`dom_id(room, :messages)` of Rails, which names the type of
## the room: `messages_rooms_open_7`), and so the target of a Turbo Stream that appends a message to it.
export def messages_id(room: Rooms.Room) -> String
  "messages_rooms_#{room.room_type.split("::").last.downcase}_#{room.id}"
end

## One message: the `<div>` with its id and `data-message-id`, the author and the time, and the body in the
## presentation `<div>` inside the frame that Turbo edits it in, then the boosts (`boosts_area`). The body is HTML that
## `Rooms.clean` (`MessageCache`, for a page) or `Rooms.post` has cleaned, the one value here that is written with
## `<%== %>`, with the links of its text made (`Autolink.link`). The markup ends with `</turbo-frame></div>`: the benchmark checks where a message ends (see
## specs/message_routes.feature). `controls` is for the person who may change the message (`Rooms.changeable?`): it
## adds the link to the edit page to the heading, after the time, and nothing else. Apart from that link and the
## boosts, the markup is the benchmark's byte for byte but for `data-creator-id`, which names the author so that the
## page can put the messages of the person who looks on the other side (`viewer_style`): the markup is the same for
## every viewer, since the live stream renders it once for all. The time is the clock of the ISO instant (UTC); the
## whole instant is in `datetime` and in `title`, so a pointer shows the date and the zone.
export def message(message: Rooms.Message, controls: Bool) -> String
  message_head(message) + edit_link(message, controls) + message_tail(message)
end

## The boosts of a message and the link to the page that adds one: the element that a new boost is appended to
## (`boost_added_stream`). The link is last, whatever the order of the elements, by the stylesheet. It is the markup
## that `GET /messages/ID/boosts` answers.
export def boosts_area(message_id: Int, boosts: List[Boosts.Boost]) -> String
  items = boosts.map do |one| boost(message_id, one) end.join("")
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <div id="boosts_message_<%= message_id %>"><%== items %><a href="<%= Routes.message_boosts_new_path(message_id) %>">Boost</a></div>
  EAG
end

## One boost: who made it and what it says. It carries a form that takes it away, which the stylesheet shows to its
## booster alone (`data-booster-id`, and the rule of `viewer_style`); the server refuses anybody else. The markup is
## the same for every viewer, since the live stream renders it once for all.
export def boost(message_id: Int, one: Boosts.Boost) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <div id="boost_<%= one.id %>" data-booster-id="<%= one.booster_id %>"><small><%= one.booster %></small><span><%= one.content %></span><form method="post" action="<%= Routes.message_boost_path(message_id, one.id) %>"><input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>"><button type="submit" class="quiet" title="Remove this boost" aria-label="Remove this boost">×</button></form></div>
  EAG
end

## The Turbo Stream that adds a boost to the message, for the people who are looking at the room, and the answer to the
## person who made it.
export def boost_added_stream(message_id: Int, one: Boosts.Boost) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="append" target="boosts_message_<%= message_id %>"><template><%== boost(message_id, one) %></template></turbo-stream>
  EAG
end

## The Turbo Stream that takes a boost off the page.
export def boost_removed_stream(boost_id: Int) -> String
  "<turbo-stream action=\"remove\" target=\"boost_#{boost_id}\"><template></template></turbo-stream>"
end

## The page that adds a boost to a message (the frame `new_boost_message_ID` that Rails loads into it): the quick
## reactions, each a button of one form, and a form for words (`text` fills it again after a refusal, `note` says why).
## Plain forms, so they work without a script; the script of the room page takes the element from this page and shows
## it under the message. `room_id` is where the way back goes.
export def new_boost(room_id: Int, message_id: Int, text: String, note: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Boost</h1>
    <% if not note.empty? %>
      <p role="alert"><%= note %></p>
    <% end %>
      <div id="new_boost_message_<%= message_id %>">
        <form method="post" action="<%= Routes.message_boosts_path(message_id) %>">
    <% for one in reactions() %>
          <button type="submit" class="quiet" name="boost[content]" value="<%= one.emoji %>" title="<%= one.title %>" aria-label="<%= one.title %>"><%= one.emoji %></button>
    <% end %>
        </form>
        <form method="post" action="<%= Routes.message_boosts_path(message_id) %>">
          <p>
            <label><span class="sr-only">Your own words</span>
              <input name="boost[content]" type="text" value="<%= text %>" autocomplete="off" required></label>
            <button type="submit" class="quiet">Boost</button>
          </p>
        </form>
        <p><a href="<%= Routes.room_at_path(room_id, message_id) %>" data-cancel>Back to the room</a></p>
      </div>
    </main>
  EAG
  layout("Boost", body)
end

## The messages one after the other, as the room page and the page of older messages write them, with the controls of
## the ones that the person (`user_id`, with the account `role`) may change.
export def messages_list(messages: List[Rooms.Message], user_id: Int, role: String) -> String
  messages.map do |one| message(one, Rooms.changeable?(one.creator_id, user_id, role)) end.join("\n")
end

## The Turbo Stream that appends the message to the list of the room: the answer of a post to the person who wrote it,
## with the controls (`controls` true), and the broadcast to the others, without.
export def message_stream(room: Rooms.Room, one: Rooms.Message, controls: Bool) -> String
  messages_appended(room, message(one, controls))
end

export def message_streams(room: Rooms.Room, one: Rooms.Message) -> MessageStreams
  head = message_head(one)
  tail = message_tail(one)
  MessageStreams(
    broadcast: messages_appended(room, head + tail),
    own: messages_appended(room, head + edit_link(one, true) + tail),
  )
end

## The Turbo Stream that shows an edited message in place of the old one, for the people who are looking at the room: no
## controls, like the broadcast of a new message.
export def message_replaced_stream(one: Rooms.Message) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="replace" target="message_<%= one.id %>"><template><%== message(one, false) %></template></turbo-stream>
  EAG
end

## The Turbo Stream that appends messages (`list`, the markup of `MessageCache.list`) to the list of the room, which
## the refresh answers for the messages that came since.
export def messages_appended(room: Rooms.Room, list: String) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="append" target="<%= messages_id(room) %>"><template><%== list %></template></turbo-stream>
  EAG
end

## The Turbo Stream that replaces a message that was edited with its new markup (`one`, from `MessageCache.list`).
export def message_replaced(message_id: Int, one: String) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="replace" target="message_<%= message_id %>"><template><%== one %></template></turbo-stream>
  EAG
end

## The Turbo Stream that takes a deleted message off the page (`destroy.turbo_stream.erb` of Rails).
export def message_removed(message_id: Int) -> String
  "<turbo-stream action=\"remove\" target=\"message_#{message_id}\"><template></template></turbo-stream>"
end

## The page that edits a message (the form in the frame `edit_message_ID` that Rails loads into the message): the text
## as `HtmlSanitizer.text_of_clean` gives it, or what was typed again after a refusal (`message` says why), a button that
## saves, and one that deletes after a question. Both are plain form posts with the `_method` of Rails' forms, so
## they work without a script.
export def edit_message(sidebar: String, room: Rooms.Room, one: Rooms.Message, text: String, note: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Edit message</h1>
    <% if not note.empty? %>
      <p role="alert"><%= note %></p>
    <% end %>
      <turbo-frame id="edit_message_<%= one.id %>">
        <form method="post" action="<%= Routes.room_message_path(room.id, one.id) %>">
          <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
          <p>
            <label><span class="sr-only">Message</span>
              <textarea name="message[body]" rows="4" required autofocus><%= text %></textarea></label>
          </p>
          <p><button type="submit">Save</button></p>
        </form>
        <form method="post" action="<%= Routes.room_message_path(room.id, one.id) %>"
          onsubmit="return confirm('Are you sure you want to delete this message?')">
          <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
          <p><button type="submit" class="danger">Delete message</button></p>
        </form>
      </turbo-frame>
      <p><a href="<%= Routes.room_path(room.id) %>" data-cancel>Back to the room</a></p>
      <script src="<%= Routes.SCRIPT %>" defer></script>
    </main>
  EAG
  layout("Edit message", body)
end

## The search page: the form, the recent searches (`recent`, the words of each, with the button that clears them) and,
## for a `query` (the words that `Searches.words` made, "" for none), the messages that match it in the markup of the
## room page. `back` is the path of the room that the link at the top goes to, "" for none. The query is shown as
## text, and only the messages carry a `data-message-id`.
export def search(
  sidebar: String,
  query: String,
  messages: List[Rooms.Message],
  recent: List[String],
  back: String,
  user_id: Int,
  role: String,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Search</h1>
    <% if not back.empty? %>
      <p><a href="<%= back %>">Back to the room</a></p>
    <% end %>
      <form method="post" action="<%= Routes.SEARCHES %>">
        <p>
          <label><span class="sr-only">Words</span>
            <input name="q" type="search" value="<%= query %>" maxlength="<%= Searches.MAX_QUERY_LENGTH %>"
              placeholder="Search messages" required autofocus></label>
        </p>
        <p><button type="submit">Search</button></p>
      </form>
    <% if not recent.empty? %>
      <h2>Recent searches</h2>
      <ul class="recent">
    <% for words in recent %>
        <li><a href="<%= Routes.search_path(words) %>"><%= words %></a></li>
    <% end %>
      </ul>
      <form method="post" action="<%= Routes.SEARCHES_CLEAR %>"
        onsubmit="return confirm('Are you sure you want to clear your recent searches?')">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
        <p><button type="submit" class="quiet">Clear recent searches</button></p>
      </form>
    <% end %>
    <% if not query.empty? and messages.empty? %>
      <p class="empty">No messages match.</p>
    <% end %>
      <div id="search_results">
    <%== messages_list(messages, user_id, role) %>
      </div>
    </main>
  EAG
  live_layout("Search", body)
end

## The avatar of a person with no picture: their `initials` in white on a circle of `color` (one of the fixed colours of
## `Avatars.color`, so it is safe in an attribute). Three letters or more are squeezed to fit, as Rails does.
export def avatar_initials(initials: String, color: String) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" class="avatar" aria-hidden="true">
      <rect width="100%" height="100%" rx="50" fill="<%= color %>"/>
      <text x="50%" y="50%" fill="#FFFFFF" text-anchor="middle" dy="0.35em"
    <% if initials.length >= 3 %>
        textLength="85%" lengthAdjust="spacingAndGlyphs"
    <% end %>
        font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
        font-size="230" font-weight="800" letter-spacing="-5"><%= initials %></text>
    </svg>
  EAG
end

## The page of a room: its messages, oldest first, with the links to the page before and back to the latest one, and
## the form that posts a message. `thread` is the markup of the messages of `page` (`MessageCache.list`, which is
## `messages_list` of them with their bodies cleaned), written with `<%== %>`. `can_edit` adds the link to the
## settings, for the people who may change the room. `sources` is the markup of the live stream of the room
## (`CableWeb.room_sources`). `me` is the id of the person who looks: the page is made for that person alone (the page
## cache keys it by person), so it may carry the one rule that sets their messages apart (`viewer_style`).
export def room(
  sidebar: String,
  room: Rooms.Room,
  page: Rooms.Page,
  thread: String,
  composer: Composer,
  can_edit: Bool,
  sources: String,
  me: Int,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main" class="room">
    <%== sources %>
      <header>
        <h1><%= room.name %></h1>
    <% if can_edit %>
        <a href="<%= Routes.room_settings_path(room.id) %>">Settings</a>
    <% end %>
    <% if room.room_type != Rooms.DIRECT %>
        <a href="<%= Routes.room_involvement_path(room.id) %>">Sidebar</a>
    <% end %>
      </header>
      <div class="scroller">
        <div class="thread">
    <% if page.older.some? %>
          <p class="more"><a href="<%= Routes.room_before_path(room.id, page.older.unwrap!) %>">Older messages</a></p>
    <% end %>
    <% if page.messages.empty? %>
          <p class="empty">No messages here yet.</p>
    <% end %>
    <div id="<%= messages_id(room) %>">
    <%== thread %>
    </div>
    <% if not page.at_latest %>
          <p class="more"><a href="<%= Routes.room_path(room.id) %>">Latest messages</a></p>
    <% end %>
        </div>
      </div>
    <% if not composer.note.empty? %>
      <p role="alert"><%= composer.note %></p>
    <% end %>
      <p aria-live="polite"></p>
      <form method="post" action="<%= Routes.room_messages_path(room.id) %>">
        <input name="message[client_message_id]" type="hidden" value="<%= composer.message_id %>">
        <p>
          <label><span class="sr-only">Message</span>
            <textarea name="message[body]" rows="1" placeholder="Message" required><%= composer.draft %></textarea></label>
        </p>
        <p><button type="submit">Send</button></p>
      </form>
      <%== viewer_style(me) %>
      <script src="<%= Routes.SCRIPT %>" defer></script>
    </main>
  EAG
  layout(room.name, body)
end

## The first-run form that makes the administrator. `name` and `email` fill the fields again after a refusal, and
## `message` says why ("" shows none). The password is never put back in the page.
export def first_run(name: String, email: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Welcome to <%= NAME %></h1>
      <p>Make the first account. It will be the administrator.</p>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.FIRST_RUN %>">
        <p>
          <label>Your name
            <input name="name" type="text" value="<%= name %>" autocomplete="name" required autofocus></label>
        </p>
        <p>
          <label>Email
            <input name="email" type="email" value="<%= email %>" autocomplete="username" required></label>
        </p>
        <p>
          <label>Password
            <input name="password" type="password" autocomplete="new-password" required></label>
        </p>
        <p><button type="submit">Make the account</button></p>
      </form>
    </main>
  EAG
  layout("Set up #{NAME}", body)
end

## The sign-in form. `email` fills its field again after a refusal, and `message` says why ("" shows none).
## `can_reset` adds the link to the password reset, which only an app that can send email has.
export def sign_in(email: String, message: String, can_reset: Bool) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Sign in to <%= NAME %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.SESSION %>">
        <p>
          <label>Email
            <input name="email_address" type="email" value="<%= email %>" autocomplete="username" required
              autofocus></label>
        </p>
        <p>
          <label>Password
            <input name="password" type="password" autocomplete="current-password" required></label>
        </p>
        <p><button type="submit">Sign in</button></p>
      </form>
    <% if can_reset %>
      <p><a href="<%= Routes.PASSWORD_RESET_NEW %>">Forgot your password?</a></p>
    <% end %>
    </main>
  EAG
  layout("Sign in to #{NAME}", body)
end

## The form that asks for the email of the account whose password is to be reset. It never shows an email again.
export def forgot_password() -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Reset your password</h1>
      <p>Enter the email of your account and we will send you a link to choose a new password.</p>
      <form method="post" action="<%= Routes.PASSWORD_RESET %>">
        <p>
          <label>Email
            <input name="email" type="email" autocomplete="username" required autofocus></label>
        </p>
        <p><button type="submit">Send the link</button></p>
      </form>
      <p><a href="<%= Routes.SIGN_IN %>">Back to sign in</a></p>
    </main>
  EAG
  layout("Reset your password", body)
end

## The answer to a request for a link. It is the same for every email, so it says what happens "if" there is an
## account.
export def reset_requested() -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Check your email</h1>
      <p>If an account has that email, we sent a link to reset its password.</p>
      <p><a href="<%= Routes.SIGN_IN %>">Back to sign in</a></p>
    </main>
  EAG
  layout("Check your email", body)
end

## The form of the new password, for the link with this token. `message` says why the last try was refused ("" shows
## none). The password is never put back in the page.
export def reset_password(token: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Choose a new password</h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.PASSWORD_RESET_UPDATE %>">
        <input name="token" type="hidden" value="<%= token %>">
        <p>
          <label>New password
            <input name="password" type="password" autocomplete="new-password" required autofocus></label>
        </p>
        <p><button type="submit">Save the password</button></p>
      </form>
    </main>
  EAG
  layout("Choose a new password", body)
end

## The page of a link that does not work: it was used, it expired, or it was never one.
export def reset_link_gone() -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>This link does not work</h1>
      <p>It may have been used already, or it may have expired.</p>
      <p><a href="<%= Routes.PASSWORD_RESET_NEW %>">Ask for a new link</a></p>
    </main>
  EAG
  layout("This link does not work", body)
end

## The text of the email that carries the link. It is plain text, so nothing here is escaped: `name` and `link` are
## written as they are, and `minutes` is how long the link works.
export def reset_mail(name: String, link: String, minutes: Int) -> String
  <<~EAG
    Hi <%= name %>,

    Someone asked to reset the password of your <%= NAME %> account. To choose a new one, open this link within
    <%= minutes %> minutes:

    <%= link %>

    If you did not ask for this, ignore this email: your password stays as it is.
  EAG
end

## The form of the join page, for the account whose join code is `code`: it posts to the page itself. `name` and `email`
## fill the fields again after a refusal, and `message` says why ("" shows none). The password is never put back.
export def join(code: String, name: String, email: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1>Join <%= NAME %></h1>
      <p>Make your account.</p>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.join_path(code) %>">
        <p>
          <label>Your name
            <input name="name" type="text" value="<%= name %>" autocomplete="name" required autofocus></label>
        </p>
        <p>
          <label>Email
            <input name="email" type="email" value="<%= email %>" autocomplete="username" required></label>
        </p>
        <p>
          <label>Password
            <input name="password" type="password" autocomplete="new-password" required></label>
        </p>
        <p><button type="submit">Join</button></p>
      </form>
    </main>
  EAG
  layout("Join #{NAME}", body)
end

## The page of a user, around the `sidebar` (`UsersController#show`). `profile` is the user and `me` the id of the person
## who reads, `admin` whether they are an administrator (who sees the email of a person). A bot shows only a button to
## write to it; a person who is not on the account any more shows only their name and that they are gone. `avatar` is
## the path of their picture, "" when the app cannot sign one.
export def user_page(sidebar: String, profile: Profiles.Detail, me: Int, admin: Bool, avatar: String) -> String
  gone = profile.status == Rails.DEACTIVATED
  bot = profile.role == Rails.BOT_NAME
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1><%= profile.name %></h1>
    <% if not avatar.empty? %>
      <p><img class="avatar" src="<%= avatar %>" alt="Profile avatar" width="120" height="120"></p>
    <% end %>
    <% if gone %>
      <p><%= profile.name %> is no longer on this account</p>
    <% else %>
    <% if not bot %>
    <% if admin and not profile.email.empty? %>
      <p><a href="mailto:<%= profile.email %>"><%= profile.email %></a></p>
    <% end %>
    <% if not profile.bio.empty? %>
      <p class="bio"><%= profile.bio %></p>
    <% end %>
    <% end %>
    <% if profile.status == Rails.ACTIVE and profile.id != me %>
      <form method="post" action="<%= Routes.DIRECT_ROOMS %>">
        <input name="member" type="hidden" value="<%= profile.id %>">
        <button type="submit">Write to <%= profile.name %></button>
      </form>
    <% end %>
    <% end %>
    <% if admin and profile.id != me and not gone and not bot %>
    <% if profile.status == Rails.BANNED %>
      <p class="banned">Banned</p>
      <form method="post" action="<%= Routes.user_ban_path(profile.id) %>"
        onsubmit="return confirm('Are you sure you want to remove the ban on this user?')">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
        <button type="submit">Remove ban</button>
      </form>
    <% else %>
      <form method="post" action="<%= Routes.user_ban_path(profile.id) %>"
        onsubmit="return confirm('Are you sure you want to ban this user? This will log them out, delete their messages, and block their IP addresses.')">
        <button type="submit" class="danger">Ban <%= profile.name %></button>
      </form>
    <% end %>
    <% end %>
    <% if profile.id == me %>
      <p><a href="<%= Routes.profile_path() %>">Edit my profile</a></p>
    <% end %>
    </main>
  EAG
  layout(profile.name, body)
end

## The profile of the person who is signed in (`Users::ProfilesController#show`), around the `sidebar`: the form of the
## name, the email address, the password (blank leaves it as it is) and the bio, which saves with a `PATCH` through the
## `_method` field, and the rooms they are in, the shared ones first and then the direct messages, each with the link to
## its sidebar setting when it has one. `typed` is the form as it was sent, for a refused save, and `note` says why. The
## picture cannot be changed to another yet: `avatar` is shown, with a button that takes it away when `removable` (it
## has one stored).
export def profile_page(
  sidebar: String,
  profile: Profiles.Detail,
  rooms: List[Rooms.Room],
  avatar: String,
  removable: Bool,
  note: String,
) -> String
  shared = rooms.select do |room| room.room_type != Rooms.DIRECT end
  direct = rooms.select do |room| room.room_type == Rooms.DIRECT end
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Your profile</h1>
    <% if not note.empty? %>
      <p role="alert"><%= note %></p>
    <% end %>
    <% if not avatar.empty? %>
      <p><img class="avatar" src="<%= avatar %>" alt="Profile avatar" width="120" height="120"></p>
    <% end %>
    <% if removable %>
      <form method="post" action="<%= Routes.own_avatar_path() %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
        <p><button type="submit" class="danger">Delete avatar</button></p>
      </form>
    <% end %>
      <form method="post" action="<%= Routes.profile_path() %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
        <p>
          <label>Name
            <input name="user[name]" type="text" value="<%= profile.name %>" autocomplete="name"
              maxlength="<%= Profiles.MAX_NAME_LENGTH %>" required></label>
        </p>
        <p>
          <label>Email address
            <input name="user[email_address]" type="email" value="<%= profile.email %>" autocomplete="username"></label>
        </p>
        <p>
          <label>New password
            <input name="user[password]" type="password" autocomplete="new-password" maxlength="72"></label>
        </p>
        <p>
          <label>Current password (needed to set a new one)
            <input name="user[password_challenge]" type="password" autocomplete="current-password" maxlength="72"></label>
        </p>
        <p>
          <label>Bio
            <textarea name="user[bio]" rows="3" maxlength="<%= Profiles.MAX_BIO_LENGTH %>"><%= profile.bio %></textarea></label>
        </p>
        <p><button type="submit">Save changes</button></p>
      </form>
      <h2>Your rooms</h2>
      <ul class="memberships">
    <% for room in shared %>
        <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a>
          <a href="<%= Routes.room_involvement_path(room.id) %>">Sidebar</a></li>
    <% end %>
    <% for room in direct %>
        <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
    <% end %>
      </ul>
    </main>
  EAG
  layout("Your profile", body)
end

## The people page, around the `sidebar`. Everybody sees the names. For an administrator (`admin`) it also has the emails,
## the roles, the buttons that deactivate and reactivate (not for `me`, who may not deactivate themselves), and the join
## `link` with the button that makes a new one; `link` is "" for anybody else.
export def users(sidebar: String, people: List[Accounts.Person], me: Int, admin: Bool, link: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>People</h1>
    <% if admin %>
      <h2>Invite people</h2>
      <p>Anybody with this link can join:</p>
      <p><code id="join-link"><%= link %></code></p>
      <form method="post" action="<%= Routes.JOIN_CODE %>">
        <p><button type="submit" class="quiet">Make a new link</button> <span class="hint">The old link stops working.</span></p>
      </form>
      <h2>Everybody</h2>
    <% end %>
      <ul class="people">
    <% for person in people %>
        <li>
          <span class="name"><a href="<%= Routes.user_path(person.id) %>"><%= person.name %></a></span>
    <% if admin %>
          <span class="meta"><%= person.email %></span>
    <% if person.role == Rooms.ADMINISTRATOR_ROLE_NAME %>
          <span class="badge">administrator</span>
    <% end %>
    <% if person.banned %>
          <span class="badge">banned</span>
    <% elsif not person.active %>
          <span class="badge">deactivated</span>
    <% end %>
    <% end %>
    <% if admin and person.id != me and person.active %>
          <form method="post" action="<%= Routes.user_deactivate_path(person.id) %>">
            <button type="submit" class="danger">Deactivate</button>
          </form>
    <% end %>
    <% if admin and not person.active and not person.banned %>
          <form method="post" action="<%= Routes.user_reactivate_path(person.id) %>">
            <button type="submit" class="quiet">Reactivate</button>
          </form>
    <% end %>
        </li>
    <% end %>
      </ul>
    </main>
  EAG
  live_layout("People", body)
end

## The page of a 503: `message` says that the server is busy.
export def busy(message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main id="main">
      <h1><%= NAME %></h1>
      <p role="alert"><%= message %></p>
    </main>
  EAG
  layout(NAME, body)
end

# The list of the sidebar that the room belongs to.
def list_id(room: Rooms.Room) -> String
  return DIRECT_ROOMS_ID if room.room_type == Rooms.DIRECT

  SHARED_ROOMS_ID
end

def room_item_id(room: Rooms.Room) -> String = "room_#{room.id}"

# The quick reactions of Rails (`EmojiHelper::REACTIONS`), in its order.
def reactions() -> List[Reaction]
  [
    Reaction(emoji: "👍", title: "Thumbs up"),
    Reaction(emoji: "👏", title: "Clapping"),
    Reaction(emoji: "👋", title: "Waving hand"),
    Reaction(emoji: "💪", title: "Muscle"),
    Reaction(emoji: "❤️", title: "Red heart"),
    Reaction(emoji: "😂", title: "Face with tears of joy"),
    Reaction(emoji: "🎉", title: "Party popper"),
    Reaction(emoji: "🔥", title: "Fire"),
  ]
end

# The link to the edit page, after the time, or nothing: an interpolated piece, so that without it `</h3>` follows
# `</time>` with no byte between, as the benchmark's markup has it.
def edit_link(message: Rooms.Message, controls: Bool) -> String
  return "" if not controls

  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <a href="<%= Routes.room_message_edit_path(message.room_id, message.id) %>">Edit</a>
  EAG
end

# The layout of a page with the sidebar, which also links the script that keeps it live (the rooms, the unread marks).
# The room page links the same script inside its `<main>`, after the composer.
def live_layout(title: String, content: String) -> String
  layout(title, content + "\n<script src=\"" + Routes.SCRIPT + "\" defer></script>")
end

# One person of the account page. The role switch offers the other role, and neither it nor the removal is drawn for
# the person who looks (the server refuses both for oneself too).
def account_person(one: Accounts.Person, me: Int, admin: Bool) -> String
  other = Rooms.ADMINISTRATOR_ROLE_NAME
  other_label = "Make administrator"
  if one.role == Rooms.ADMINISTRATOR_ROLE_NAME
    other = Rooms.MEMBER_ROLE_NAME
    other_label = "Make member"
  end

  <<~EAG
    <%@ escape &Bond.escape %>
    <li>
      <span class="name"><%= one.name %></span>
    <% if admin %>
      <span class="meta"><%= one.email %></span>
    <% end %>
    <% if one.role == Rooms.ADMINISTRATOR_ROLE_NAME %>
      <span class="badge">administrator</span>
    <% end %>
    <% if admin and one.id != me %>
      <form method="post" action="<%= Routes.account_user_path(one.id) %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PATCH %>">
        <input name="user[role]" type="hidden" value="<%= other %>">
        <button type="submit" class="quiet"><%= other_label %></button>
      </form>
      <form method="post" action="<%= Routes.account_user_path(one.id) %>"
        onsubmit="return confirm('Are you sure you want to remove this person from the account? They cannot sign in until an administrator reactivates them.')">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_DELETE %>">
        <button type="submit" class="danger">Remove</button>
      </form>
    <% end %>
    </li>
  EAG
end

def sidebar_choice(level: String) -> String
  return "Hidden from the sidebar" if Rooms.hidden?(level)

  "Shown in the sidebar"
end

# The messages of the person who looks sit on the other side, in the accent colour. The stylesheet reads six custom
# properties (`components/messages`) with the other people's values as their defaults; this one rule sets them for the
# messages of `me`. A second rule shows the form that takes a boost away on the boosts of `me` (`--boost-remove`; it is
# hidden on all others). It
# is in the page, not the stylesheet, because the stylesheet is the same for everybody and so is the HTML of a message:
# the viewer is the only thing that differs, and a CSS rule can compare an attribute with a number only when it is
# written out.
def viewer_style(me: Int) -> String
  (
    "<style>.thread [data-creator-id=\"#{me}\"]{--bubble-bg:var(--accent);--bubble-fg:var(--accent-fg);--bubble-meta:var(--accent-fg);--bubble-link:var(--accent-fg);--bubble-side:end;--bubble-name:none}.thread [data-booster-id=\"#{me}\"]{--boost-remove:grid}</style>"
  )
end

# `09:05` of `2026-03-01T09:05:00.000Z`.
def clock(iso: String) -> String = iso.slice(11, 5)

# The markup of a message up to the end of the time, where the link to the edit page goes, and from there to the end.
# The two parts are all of `message` (and the tail is the costly one: the body and the boosts), so a caller that
# needs both the markup with the link and without it writes the tail once (`message_streams`).
def message_head(message: Rooms.Message) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    <div id="message_<%= message.id %>" data-message-id="<%= message.id %>" data-creator-id="<%= message.creator_id %>">
      <h3><strong><%= message.author %></strong>
        <time datetime="<%= message.created_at %>" title="<%= message.created_at %>"><%= clock(message.created_at) %></time>
  EAG
end

def message_tail(message: Rooms.Message) -> String
  <<~EAG.strip
    <%@ escape &Bond.escape %>
    </h3>
      <turbo-frame id="edit_message_<%= message.id %>"><div id="presentation_message_<%= message.id %>"><%== Autolink.link(message.body) %></div><%== boosts_area(message.id, message.boosts) %></turbo-frame></div>
  EAG
end
