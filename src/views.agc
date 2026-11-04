## The pages, as EAG templates. A template with `<%@ escape &Bond.escape %>` escapes every `<%= %>`, so a value goes
## into the page as text; `<%== %>` is the way out, only for markup that this program wrote itself.

import EAG from "std/eag"
import Bond from "pkg/bond/bond"
import Routes from "routes"

# The name of the app, in the title and the heading.
NAME = "Campfire"

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

## The home page of the person who is signed in, with the button to sign out.
export def home(user_name: String) -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main>
      <h1><%= NAME %></h1>
      <p>Group chat, written in Agentica.</p>
      <p>Signed in as <%= user_name %></p>
      <form method="post" action="<%= Routes.SIGN_OUT %>">
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
