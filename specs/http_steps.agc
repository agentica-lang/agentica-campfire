## The HTTP steps of the features: a small browser that talks to the app on 127.0.0.1 with the client of `std/http`.
## It keeps the cookies of the answers and sends them back (the client has no cookie jar and does not follow a
## redirect, so a step sees the 302 itself), and can add a header to every request, such as `Sec-Fetch-Site`.

import BDD from "std/bdd"
import HTTP from "std/http"
import URI from "std/uri"

## The scenario value that holds the port of the app, set when the app says where it listens.
export PORT = "port"

## The first person that `the first admin exists` makes, and the steps use to sign in again.
export ADMIN_EMAIL = "ana@example.com"
export ADMIN_PASSWORD = "correct horse battery"

REPLY = "reply"
BROWSER = "browser"
FORM_TYPE = "application/x-www-form-urlencoded"

struct Reply
  status: Int
  headers: Map[String, String]
  body: String
end

# `saved` is the copy that `the browser saves a copy of its cookies` makes.
struct Browser
  cookies: Map[String, String]
  saved: Map[String, String]
  headers: Map[String, String]
end

## The steps that talk to the app and read its last answer.
export def steps() -> List[BDD.Step]
  return [
    BDD.step("I get {string}", &get),
    BDD.step("I post to {string} the form:", &post_form),
    BDD.step("I post nothing to {string}", &post_nothing),
    BDD.step("the first admin exists", &first_admin),
    BDD.step("the status is {int}", &status_is),
    BDD.step("the header {string} is {string}", &header_is),
    BDD.step("the header {string} contains {string}", &header_contains),
    BDD.step("the body is {string}", &body_is),
    BDD.step("the body contains {string}", &body_contains),
    BDD.step("the body does not contain {string}", &body_lacks),
    BDD.step("the browser has no cookies", &forget_cookies),
    BDD.step("the browser saves a copy of its cookies", &save_cookies),
    BDD.step("the browser restores its saved cookies", &restore_cookies),
    BDD.step("the browser has the cookie {string} with the value {string}", &set_cookie),
    BDD.step("the request header {string} is {string}", &set_header),
  ]
end

## The last answer of the app, for the steps that read its body.
export def last_body(ctx: BDD.Context) -> String
  return last_reply(ctx).body
end

## Gets `args[0]`, a path, with the cookies of the browser.
export def get(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, "GET", args[0], "")
end

# The table has one field per row: its name, then its value.
def post_form(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  return send(ctx, "POST", args[0], URI.encode_www_form(pairs))
end

def post_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, "POST", args[0], "")
end

# Through the first-run form, so the browser ends signed in as that person, like the person who sets the app up.
def first_admin(ctx: BDD.Context, args: List[String]) -> BDD.Context
  form = URI.encode_www_form([
    URI.Pair(name: "name", value: "Ana"),
    URI.Pair(name: "email", value: ADMIN_EMAIL),
    URI.Pair(name: "password", value: ADMIN_PASSWORD),
  ])

  made = send(ctx, "POST", "/first_run", form)
  return BDD.assert(made, last_reply(made).status == 302, "the first run answered #{last_reply(made).status}")
end

def send(ctx: BDD.Context, method: String, path: String, body: String) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  state = browser(ctx)
  headers = state.headers.keys.map do |name| Header(name: name, value: state.headers.get(name, "")) end
  if not state.cookies.empty?
    pairs = state.cookies.keys.map do |name| "#{name}=#{state.cookies.get(name, "")}" end
    headers = headers.push(Header(name: "cookie", value: pairs.join("; ")))
  end

  if method == "POST"
    headers = headers.push(Header(name: "content-type", value: FORM_TYPE))
  end

  client = HTTP.client().unwrap!
  response = HTTP.request(client, method, "http://127.0.0.1:#{port}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  if not response.ok?
    return BDD.assert(ctx, false, "#{method} #{path} failed: #{response.message}")
  end

  reply = reply_of(response.unwrap!)
  kept = state.with(cookies: cookies_after(state.cookies, response.unwrap!))
  return BDD.set(BDD.set(ctx, REPLY, JSON.from(reply)), BROWSER, JSON.from(kept))
end

# A `Set-Cookie` with an empty value, or `Max-Age=0`, deletes the cookie, as a browser does.
def cookies_after(cookies: Map[String, String], response: HttpResponse) -> Map[String, String]
  lines = HTTP.header_values(response.headers, "set-cookie")
  return lines.reduce(cookies) do |kept, line| apply_set_cookie(kept, line) end
end

def apply_set_cookie(cookies: Map[String, String], line: String) -> Map[String, String]
  parts = line.split(";").map do |part| part.strip end
  at = parts[0].index_of("=").unwrap_or(-1)
  if at < 1
    return cookies
  end

  name = parts[0].slice(0, at)
  value = parts[0].slice(at + 1, parts[0].length - at - 1)
  if value.empty? or parts.include?("Max-Age=0")
    return cookies.delete(name)
  end

  return cookies.put(name, value)
end

def reply_of(response: HttpResponse) -> Reply
  start: Map[String, String] = {}
  headers = response.headers.reduce(start) do |acc, header| acc.put(header.name.downcase, header.value) end
  body = String.from_bytes(response.body).unwrap_or("")
  return Reply(status: response.status, headers: headers, body: body)
end

def last_reply(ctx: BDD.Context) -> Reply
  return JSON.decode(BDD.get(ctx, REPLY).unwrap!, Reply).unwrap!
end

def browser(ctx: BDD.Context) -> Browser
  empty = Browser(cookies: {}, saved: {}, headers: {})
  stored = BDD.get(ctx, BROWSER)
  if not stored.ok?
    return empty
  end

  return JSON.decode(stored.unwrap!, Browser).unwrap_or(empty)
end

def forget_cookies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, BROWSER, JSON.from(browser(ctx).with(cookies: {})))
end

def save_cookies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  state = browser(ctx)
  return BDD.set(ctx, BROWSER, JSON.from(state.with(saved: state.cookies)))
end

def restore_cookies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  state = browser(ctx)
  return BDD.set(ctx, BROWSER, JSON.from(state.with(cookies: state.saved)))
end

def set_cookie(ctx: BDD.Context, args: List[String]) -> BDD.Context
  state = browser(ctx)
  return BDD.set(ctx, BROWSER, JSON.from(state.with(cookies: state.cookies.put(args[0], args[1]))))
end

def set_header(ctx: BDD.Context, args: List[String]) -> BDD.Context
  state = browser(ctx)
  return BDD.set(ctx, BROWSER, JSON.from(state.with(headers: state.headers.put(args[0].downcase, args[1]))))
end

def status_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.status == args[0].to_i!, "the status is #{reply.status}")
end

def header_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.headers.get(args[0].downcase, "") == args[1], "the headers are #{reply.headers}")
end

def header_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  value = reply.headers.get(args[0].downcase, "")
  return BDD.assert(ctx, value.include?(args[1]), "the header #{args[0]} is #{value.inspect}")
end

def body_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body == args[0], "the body is #{reply.body}")
end

def body_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body.include?(args[0]), "the body is #{reply.body}")
end

def body_lacks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, not reply.body.include?(args[0]), "the body is #{reply.body}")
end
