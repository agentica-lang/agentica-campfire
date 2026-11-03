## The pages, as EAG templates. A template with `<%@ escape &Bond.escape %>` escapes every `<%= %>`, so a value goes
## into the page as text; `<%== %>` is the way out, only for markup that this program wrote itself.

import EAG from "std/eag"
import Bond from "pkg/bond/bond"

## The name of the app, in the title and the heading.
export NAME = "Campfire"

## The page around `content`, which is HTML that the caller made safe (another template, never a value of a client).
## `title` is text, and is escaped.
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

## The home page of the person who is signed in, with the button to sign out.
export def home(user_name: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main>
      <h1><%= NAME %></h1>
      <p>Group chat, written in Agentica.</p>
      <p>Signed in as <%= user_name %></p>
      <form method="post" action="/sign_out">
        <button type="submit">Sign out</button>
      </form>
    </main>
  EAG
  return layout(NAME, body)
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
      <form method="post" action="/first_run">
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
export def sign_in(email: String, message: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main>
      <h1>Sign in to <%= NAME %></h1>
    <% if not message.empty? %>
      <p role="alert"><%= message %></p>
    <% end %>
      <form method="post" action="/session">
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
    </main>
  EAG
  return layout("Sign in to #{NAME}", body)
end
