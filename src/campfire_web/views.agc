## The pages, as EAG templates. A template with `<%@ escape &Bond.escape %>` escapes every `<%= %>`, so a value goes
## into the page as text; `<%== %>` is the way out, only for markup that this program wrote itself.

import EAG from "std/eag"
import Bond from "pkg/bond/bond"
import Accounts from "../campfire/accounts"
import Rooms from "../campfire/rooms"
import Searches from "../campfire/searches"
import Routes from "routes"

# The name of the app, in the title and the heading.
NAME = "Campfire"

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
  return <<~EAG
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
## when the account lets only administrators make a shared room: the two links to those forms are then left out. It is raw HTML that this file
## made, for the pages below to put in.
export def sidebar(user_name: String, rooms: List[Rooms.Room], can_create: Bool) -> String
  shared = rooms.select do |room| room.room_type != Rooms.DIRECT end
  direct = rooms.select do |room| room.room_type == Rooms.DIRECT end
  return <<~EAG
    <%@ escape &Bond.escape %>
    <nav aria-label="Rooms">
      <a class="skip" href="#main">Skip to the page</a>
      <p class="who">Signed in as <%= user_name %></p>
      <div class="lists">
        <h2>Rooms</h2>
        <ul id="shared_rooms">
    <% for room in shared %>
          <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
    <% end %>
        </ul>
    <% if not direct.empty? %>
        <h2>Direct messages</h2>
        <ul>
    <% for room in direct %>
          <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
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
    </main>
  EAG
  return layout("Account settings", body)
end

## The sidebar alone as a document, for `GET /users/me/sidebar`.
export def sidebar_page(sidebar: String) -> String
  return layout("Rooms", sidebar)
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
  return layout(NAME, body)
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
  return layout("New room", body)
end

## The people to pick, as checkboxes named `member` with their ids as values: the ones whose id is in `chosen` come
## checked. It is raw HTML that this file made, for the forms below to put in.
export def member_picker(people: List[Rooms.Person], chosen: List[Int]) -> String
  return <<~EAG
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
  return layout("New closed room", body)
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
  return layout("New direct message", body)
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
  return layout("Settings of #{room.name}", body)
end

## The page where a person sets how much a room notifies them: a radio for each of the `levels` that the room offers,
## the `current` one checked, and a plain form post with the `_method` field of Rails' forms, so it works without a
## script. `message` says why a save was refused.
export def involvement(
  sidebar: String,
  room: Rooms.Room,
  levels: List[String],
  current: String,
  message: String,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Notifications for <%= room.name %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.room_involvement_path(room.id) %>">
        <input name="_method" type="hidden" value="<%= Routes.METHOD_PUT %>">
    <% for level in levels %>
        <p>
    <% if level == current %>
          <label><input name="involvement" type="radio" value="<%= level %>" checked>
            <%= Rooms.involvement_label(level) %></label>
    <% else %>
          <label><input name="involvement" type="radio" value="<%= level %>">
            <%= Rooms.involvement_label(level) %></label>
    <% end %>
        </p>
    <% end %>
        <p><button type="submit">Save</button></p>
      </form>
      <p><a href="<%= Routes.room_path(room.id) %>">Back to the room</a></p>
    </main>
  EAG
  return layout("Notifications for #{room.name}", body)
end

## The form that deletes a room (the button of the settings page, as `button_to_delete_room` is in Rails). It is a plain
## form post with the `_method` field that Rails' forms send, so it works without a script; the `onsubmit` asks first
## and a script-less browser skips the question, as the form of Rails does without Turbo.
export def delete_form(room: Rooms.Room) -> String
  return <<~EAG
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
  return "messages_rooms_#{room.room_type.split("::").last.downcase}_#{room.id}"
end

## One message: the `<div>` with its id and `data-message-id`, the author and the time, and the body in the presentation
## `<div>` inside the frame that Turbo edits it in. The body is HTML that `Rooms.clean` (`MessageCache`, for a page) or
## `Rooms.post` has cleaned, the one value here that is written with `<%== %>`. The markup ends with `</turbo-frame></div>`: the benchmark checks
## where a message ends (see specs/message_routes.feature). `controls` is for the person who may change the message
## (`Rooms.changeable?`): it adds the link to the edit page to the heading, after the time, and nothing else, so for
## everybody else the markup is the benchmark's byte for byte.
export def message(message: Rooms.Message, controls: Bool) -> String
  return <<~EAG.strip
    <%@ escape &Bond.escape %>
    <div id="message_<%= message.id %>" data-message-id="<%= message.id %>">
      <h3><strong><%= message.author %></strong>
        <time datetime="<%= message.created_at %>"><%= message.created_at %></time><%== edit_link(message, controls) %></h3>
      <turbo-frame id="edit_message_<%= message.id %>"><div id="presentation_message_<%= message.id %>"><%== message.body %></div></turbo-frame></div>
  EAG
end

## The messages one after the other, as the room page and the page of older messages write them, with the controls of
## the ones that the person (`user_id`, with the account `role`) may change.
export def messages_list(messages: List[Rooms.Message], user_id: Int, role: String) -> String
  return messages.map do |one| message(one, Rooms.changeable?(one.creator_id, user_id, role)) end.join("\n")
end

## The Turbo Stream that appends the message to the list of the room, which a post answers to a browser. The person who
## posts wrote it, so it has the controls.
export def message_stream(room: Rooms.Room, one: Rooms.Message) -> String
  return <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="append" target="<%= messages_id(room) %>"><template><%== message(one, true) %></template></turbo-stream>
  EAG
end

## The Turbo Stream that appends messages (`list`, the markup of `MessageCache.list`) to the list of the room, which
## the refresh answers for the messages that came since.
export def messages_appended(room: Rooms.Room, list: String) -> String
  return <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="append" target="<%= messages_id(room) %>"><template><%== list %></template></turbo-stream>
  EAG
end

## The Turbo Stream that replaces a message that was edited with its new markup (`one`, from `MessageCache.list`).
export def message_replaced(message_id: Int, one: String) -> String
  return <<~EAG.strip
    <%@ escape &Bond.escape %>
    <turbo-stream action="replace" target="message_<%= message_id %>"><template><%== one %></template></turbo-stream>
  EAG
end

## The Turbo Stream that takes a deleted message off the page (`destroy.turbo_stream.erb` of Rails).
export def message_removed(message_id: Int) -> String
  return "<turbo-stream action=\"remove\" target=\"message_#{message_id}\"><template></template></turbo-stream>"
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
      <script src="<%= Routes.COMPOSER_SCRIPT %>" defer></script>
    </main>
  EAG
  return layout("Edit message", body)
end

## The search page: the form, the recent searches (`recent`, the words of each) and, for a `query` (the words that
## `Searches.words` made, "" for none), the messages that match it in the markup of the room page. The query is shown as
## text, and only the messages carry a `data-message-id`.
export def search(
  sidebar: String,
  query: String,
  messages: List[Rooms.Message],
  recent: List[String],
  user_id: Int,
  role: String,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main">
      <h1>Search</h1>
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
    <% end %>
    <% if not query.empty? and messages.empty? %>
      <p class="empty">No messages match.</p>
    <% end %>
      <div id="search_results">
    <%== messages_list(messages, user_id, role) %>
      </div>
    </main>
  EAG
  return layout("Search", body)
end

## The avatar of a person with no picture: their `initials` in white on a circle of `color` (one of the fixed colours of
## `Avatars.color`, so it is safe in an attribute). Three letters or more are squeezed to fit, as Rails does.
export def avatar_initials(initials: String, color: String) -> String
  return <<~EAG.strip
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
## settings, for the people who may change the room.
export def room(
  sidebar: String,
  room: Rooms.Room,
  page: Rooms.Page,
  thread: String,
  composer: Composer,
  can_edit: Bool,
) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main id="main" class="room">
      <header>
        <h1><%= room.name %></h1>
    <% if can_edit %>
        <a href="<%= Routes.room_settings_path(room.id) %>">Settings</a>
    <% end %>
        <a href="<%= Routes.room_involvement_path(room.id) %>">Notifications</a>
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
      <script src="<%= Routes.COMPOSER_SCRIPT %>" defer></script>
    </main>
  EAG
  return layout(room.name, body)
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
  return layout("Set up #{NAME}", body)
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
  return layout("Sign in to #{NAME}", body)
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
  return layout("Reset your password", body)
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
  return layout("Check your email", body)
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
  return layout("Choose a new password", body)
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
  return layout("This link does not work", body)
end

## The text of the email that carries the link. It is plain text, so nothing here is escaped: `name` and `link` are
## written as they are, and `minutes` is how long the link works.
export def reset_mail(name: String, link: String, minutes: Int) -> String
  return <<~EAG
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
  return layout("Join #{NAME}", body)
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
          <span class="name"><%= person.name %></span>
    <% if admin %>
          <span class="meta"><%= person.email %></span>
    <% if person.role == Rooms.ADMINISTRATOR_ROLE_NAME %>
          <span class="badge">administrator</span>
    <% end %>
    <% if not person.active %>
          <span class="badge">deactivated</span>
    <% end %>
    <% end %>
    <% if admin and person.id != me and person.active %>
          <form method="post" action="<%= Routes.user_deactivate_path(person.id) %>">
            <button type="submit" class="danger">Deactivate</button>
          </form>
    <% end %>
    <% if admin and not person.active %>
          <form method="post" action="<%= Routes.user_reactivate_path(person.id) %>">
            <button type="submit" class="quiet">Reactivate</button>
          </form>
    <% end %>
        </li>
    <% end %>
      </ul>
    </main>
  EAG
  return layout("People", body)
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
  return layout(NAME, body)
end

# The link to the edit page, after the time, or nothing: an interpolated piece, so that without it `</h3>` follows
# `</time>` with no byte between, as the benchmark's markup has it.
def edit_link(message: Rooms.Message, controls: Bool) -> String
  if not controls
    return ""
  end

  return <<~EAG.strip
    <%@ escape &Bond.escape %>
    <a href="<%= Routes.room_message_edit_path(message.room_id, message.id) %>">Edit</a>
  EAG
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

  return <<~EAG
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
