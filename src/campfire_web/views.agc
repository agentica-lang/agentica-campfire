## The pages, as EAG templates. A template with `<%@ escape &Bond.escape %>` escapes every `<%= %>`, so a value goes
## into the page as text; `<%== %>` is the way out, only for markup that this program wrote itself.

import EAG from "std/eag"
import Bond from "pkg/bond/bond"
import Accounts from "../campfire/accounts"
import Rooms from "../campfire/rooms"
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
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title><%= title %></title>
    </head>
    <body>
    <%== content.strip %>
    </body>
    </html>
  EAG
end

## The column at the side of every page of a person who is signed in: who they are, their rooms (the direct messages
## apart, named after the other people) and the ways to make a room and to sign out. It is raw HTML that this file
## made, for the pages below to put in.
export def sidebar(user_name: String, rooms: List[Rooms.Room]) -> String
  shared = rooms.select do |room| room.kind != Rooms.DIRECT end
  direct = rooms.select do |room| room.kind == Rooms.DIRECT end
  return <<~EAG
    <%@ escape &Bond.escape %>
    <nav aria-label="Rooms">
      <p>Signed in as <%= user_name %></p>
      <h2>Rooms</h2>
      <ul>
    <% for room in shared %>
        <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
    <% end %>
      </ul>
      <p><a href="<%= Routes.ROOM_NEW %>">New room</a></p>
      <p><a href="<%= Routes.CLOSED_ROOM_NEW %>">New closed room</a></p>
      <p><a href="<%= Routes.DIRECT_ROOM_NEW %>">New direct message</a></p>
      <p><a href="<%= Routes.USERS %>">People</a></p>
    <% if not direct.empty? %>
      <h2>Direct messages</h2>
      <ul>
    <% for room in direct %>
        <li><a href="<%= Routes.room_path(room.id) %>"><%= room.name %></a></li>
    <% end %>
      </ul>
    <% end %>
      <form method="post" action="<%= Routes.SIGN_OUT %>">
        <button type="submit">Sign out</button>
      </form>
    </nav>
  EAG
end

## The home page of the person who is signed in, around their `sidebar`.
export def home(sidebar: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main>
      <h1><%= NAME %></h1>
      <p>Group chat, written in Agentica.</p>
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
    <main>
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
    <main>
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
    <main>
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

## The settings of a closed room: its name and who is in it (`chosen` of `people`, the others than the person who is
## looking, who stays). The form sends the ids of the people who were in the room when it was drawn (`was`), so that
## saving it takes out only those that it unchecked, not someone who was put in after the page was drawn. `name` and
## `message` fill the form again after a refusal.
export def room_settings(
  sidebar: String,
  room: Rooms.Room,
  name: String,
  people: List[Rooms.Person],
  chosen: List[Int],
  was: List[Int],
  message: String,
) -> String
  picker = member_picker(people, chosen)
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main>
      <h1>Settings of <%= room.name %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.room_settings_path(room.id) %>">
        <p>
          <label>Name
            <input name="name" type="text" value="<%= name %>" maxlength="<%= Rooms.MAX_NAME_LENGTH %>"
              required autofocus></label>
        </p>
        <%== picker.strip %>
    <% for person in people %>
    <% if was.include?(person.id) %>
        <input name="was" type="hidden" value="<%= person.id %>">
    <% end %>
    <% end %>
        <p><button type="submit">Save</button></p>
      </form>
      <p><a href="<%= Routes.room_path(room.id) %>">Back to the room</a></p>
    </main>
  EAG
  return layout("Settings of #{room.name}", body)
end

## The page of a room: its messages, oldest first, with the links to the page before and back to the latest one, and
## the form that posts a message. `can_edit` adds the link to the settings, for the people who may change the room.
export def room(sidebar: String, room: Rooms.Room, page: Rooms.Page, composer: Composer, can_edit: Bool) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <%== sidebar %>
    <main>
      <h1><%= room.name %></h1>
    <% if can_edit %>
      <p><a href="<%= Routes.room_settings_path(room.id) %>">Settings</a></p>
    <% end %>
    <% if page.older.some? %>
      <p><a href="<%= Routes.room_before_path(room.id, page.older.unwrap!) %>">Older messages</a></p>
    <% end %>
    <% if page.messages.empty? %>
      <p>No messages here yet.</p>
    <% end %>
    <% for message in page.messages %>
      <article id="message_<%= message.id %>">
        <header>
          <strong><%= message.author %></strong>
          <time datetime="<%= message.created_at %>"><%= message.created_at %></time>
        </header>
        <div style="white-space: pre-wrap"><%= message.body %></div>
      </article>
    <% end %>
    <% if not page.at_latest %>
      <p><a href="<%= Routes.room_path(room.id) %>">Latest messages</a></p>
    <% end %>
    <% if not composer.note.empty? %>
      <p role="alert"><%= composer.note %></p>
    <% end %>
      <form method="post" action="<%= Routes.room_messages_path(room.id) %>">
        <input name="client_message_id" type="hidden" value="<%= composer.message_id %>">
        <p>
          <label>Message
            <textarea name="body" required autofocus><%= composer.draft %></textarea></label>
        </p>
        <p><button type="submit">Send</button></p>
      </form>
    </main>
  EAG
  return layout(room.name, body)
end

## The first-run form that makes the administrator. `name` and `email` fill the fields again after a refusal, and
## `message` says why ("" shows none). The password is never put back in the page.
export def first_run(name: String, email: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main>
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
    <main>
      <h1>Sign in to <%= NAME %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="<%= Routes.SESSION %>">
        <p>
          <label>Email
            <input name="email" type="email" value="<%= email %>" autocomplete="username" required autofocus></label>
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
    <main>
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
    <main>
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
    <main>
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
    <main>
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
    <main>
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
    <main>
      <h1>People</h1>
    <% if admin %>
      <h2>Invite people</h2>
      <p>Anybody with this link can join: <code id="join-link"><%= link %></code></p>
      <form method="post" action="<%= Routes.JOIN_CODE %>">
        <p><button type="submit">Make a new link</button> The old link stops working.</p>
      </form>
    <% end %>
      <ul>
    <% for person in people %>
        <li>
          <%= person.name %>
    <% if admin %>
          (<%= person.email %><% if person.role == Rooms.ADMINISTRATOR %>, administrator<% end %><% if not person.active %>, deactivated<% end %>)
    <% end %>
    <% if admin and person.id != me and person.active %>
          <form method="post" action="<%= Routes.user_deactivate_path(person.id) %>">
            <button type="submit">Deactivate</button>
          </form>
    <% end %>
    <% if admin and not person.active %>
          <form method="post" action="<%= Routes.user_reactivate_path(person.id) %>">
            <button type="submit">Reactivate</button>
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
    <main>
      <h1><%= NAME %></h1>
      <p role="alert"><%= message %></p>
    </main>
  EAG
  return layout(NAME, body)
end
