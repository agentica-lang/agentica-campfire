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

## The home page.
export def home() -> String
  body = <<~EAG
    <%@ escape &Bond.escape %>
    <main>
      <h1><%= NAME %></h1>
      <p>Group chat, written in Agentica.</p>
    </main>
  EAG
  return layout(NAME, body)
end
