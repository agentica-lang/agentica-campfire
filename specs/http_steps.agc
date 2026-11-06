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

## The password of every other person that `a member ... exists` makes.
export MEMBER_PASSWORD = "another long password"

REPLY = "reply"
REMEMBERED = "remembered_reply"
THREAD = "remembered_thread"
# The messages of a room page: from the start of the thread to the form that posts (which holds an id that every page
# draws anew, so the whole page differs from one answer to the next).
THREAD_START = "<div class=\"thread\">"
THREAD_END = "<form method=\"post\" action=\"/rooms/"
JOIN_LINK = "join_link"
STATUSES = "statuses"
ALL_AT_ONCE_MS = 60_000
BROWSER = "browser"
FORM_TYPE = "application/x-www-form-urlencoded"
# A WebP file starts with `RIFF`, four bytes of size and `WEBP`: 12 bytes.
HEAD_BYTES = 12
WEBP_MAGIC_START = "52494646"
WEBP_MAGIC_END = "57454250"

# `body` is the text of the body ("" for one that is not UTF-8), so `size`, `sha256` (hex) and `head` (the first
# bytes in hex) say what a binary body is. `path` is what was asked for.
struct Reply
  status: Int
  headers: Map[String, String]
  body: String
  elapsed_ms: Int
  path: String
  size: Int
  sha256: String
  head: String
end

# What a parallel request answered: the status, the `Retry-After` header ("" when it has none) and the body.
struct Answer
  status: Int
  retry_after: String
  body: String
end

struct Answers
  values: List[Answer]
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
    BDD.step("I post to {string} {int} times at once the form:", &post_form_at_once),
    BDD.step("I post {int} messages at once to {string}", &post_messages_at_once),
    BDD.step("I post to {string} a message of {int} characters", &post_message_of_length),
    BDD.step("I post to {string} a message that starts with {string} and has {int} characters", &post_long_message),
    BDD.step("I post nothing to {string}", &post_nothing),
    BDD.step("I send a DELETE to {string}", &delete_to),
    BDD.step("I submit the form of the page that posts to {string}", &submit_page_form),
    BDD.step("I submit the join form of the page with:", &submit_join_form),
    BDD.step("I remember the join link", &remember_join_link),
    BDD.step("I get the join link that I remembered", &get_remembered_join_link),
    BDD.step("I post to the join link that I remembered the form:", &post_to_remembered_join_link),
    BDD.step("the join link of the page is not the one that I remembered", &join_link_changed),
    BDD.step("I sign in as {string}", &sign_in_as),
    BDD.step("the first admin exists", &first_admin),
    BDD.step("I remember the answer", &remember_answer),
    BDD.step("the answer is the one that I remembered", &answer_is_remembered),
    BDD.step("the answer is not the one that I remembered", &answer_is_not_remembered),
    BDD.step("the request header {string} is the header {string} of the answer", &send_header_of_answer),
    BDD.step("I remember the messages of the page", &remember_thread),
    BDD.step("the messages of the page are the ones that I remembered", &thread_is_remembered),
    BDD.step("the body contains the message of the answer that I remembered", &body_has_remembered_message),
    BDD.step("the answer came within {int} milliseconds", &answer_was_quick),
    BDD.step("the status is {int}", &status_is),
    BDD.step("the header {string} is {string}", &header_is),
    BDD.step("the header {string} contains {string}", &header_contains),
    BDD.step("the header {string} is a whole number from {int} to {int}", &header_is_number_between),
    BDD.step("the header {string} does not contain {string}", &header_lacks),
    BDD.step("each status is one of {string}", &each_status_is_one_of),
    BDD.step("at least one status is {int}", &some_status_is),
    BDD.step("exactly {int} statuses are {int}", &count_statuses),
    BDD.step("each 503 answer has the header \"retry-after\" {string}", &each_503_says_retry_after),
    BDD.step("each 503 answer has a body that contains {string}", &each_503_body_contains),
    BDD.step("the body is {string}", &body_is),
    BDD.step("the body contains {string}", &body_contains),
    BDD.step("the body does not contain {string}", &body_lacks),
    BDD.step("the body contains {string} {int} times", &body_contains_times),
    BDD.step("the body starts with {string}", &body_starts_with),
    BDD.step("the body is a WebP image", &body_is_webp),
    BDD.step("I get the stylesheet that the page links", &get_stylesheet),
    BDD.step("I get the script that the page links", &get_script),
    BDD.step("the body has the SHA-256 that starts with the digest in the name of the file", &body_has_digest),
    BDD.step("the body ends with {string}", &body_ends_with),
    BDD.step("the body shows {string} before {string}", &body_shows_before),
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

## Posts `body`, a form that a step encoded, to `path`.
export def post(ctx: BDD.Context, path: String, body: String) -> BDD.Context
  return send(ctx, "POST", path, body)
end

## Posts `body` to `path` `count` times in parallel with the browser as it is, and keeps the statuses (see
## `I post to {string} {int} times at once the form:`).
export def post_at_once(ctx: BDD.Context, path: String, body: String, count: Int) -> BDD.Context
  port = port_of(ctx)
  state = browser(ctx)
  attempts = (1..count).to_a
  answers = Task.map(attempts, count, ALL_AT_ONCE_MS) do |_| post_answer(port, state, path, body) end
  return keep_answers(ctx, answers)
end

## Whether the body of the last answer is, byte for byte, the file at `path`.
export def body_is_file(ctx: BDD.Context, path: String) -> BDD.Context
  reply = last_reply(ctx)
  expected = File.sha256(path)
  if not expected.ok?
    return BDD.assert(ctx, false, "cannot read #{path}: #{expected.message}")
  end

  same = reply.sha256 == Digest.hexencode(expected.unwrap!)
  return BDD.assert(ctx, same, "the body (#{reply.size} bytes) is not the file #{path}")
end

## Posts `args[0]` messages to the room path `args[1]` in parallel, each with a body and a `client_message_id` of its
## own, and keeps the statuses.
def post_messages_at_once(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = port_of(ctx)
  state = browser(ctx)
  count = args[0].to_i!
  answers = Task.map((1..count).to_a, count, ALL_AT_ONCE_MS) do |n|
    form = URI.encode_www_form([
      URI.Pair(name: "message[body]", value: "burst #{n}"),
      URI.Pair(name: "message[client_message_id]", value: "burst-#{n}"),
    ])

    post_answer(port, state, args[1], form)
  end

  return keep_answers(ctx, answers)
end

# The statuses of the parallel requests, for the steps that read them. A request that did not get an answer at all
# fails the step.
def keep_answers(ctx: BDD.Context, answers: List[Result[Answer]]) -> BDD.Context
  failed = answers.select do |answer| not answer.ok? end
  if not failed.empty?
    return BDD.assert(ctx, false, "a request failed: #{failed[0].message}")
  end

  return BDD.set(ctx, STATUSES, JSON.from(Answers(values: answers.map do |answer| answer.unwrap! end)))
end

# The table has one field per row: its name, then its value.
def post_form(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  return send(ctx, "POST", args[0], URI.encode_www_form(pairs))
end

# A `body` of `args[1]` letters, for the limit on the size of a message.
def post_message_of_length(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = List.repeat("x", args[1].to_i!).join("")
  return send(ctx, "POST", args[0], URI.encode_www_form([URI.Pair(name: "message[body]", value: text)]))
end

# A `body` that starts with `args[1]` and is padded with letters to `args[2]` characters.
def post_long_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  padding = List.repeat("x", args[2].to_i! - args[1].length).join("")
  return send(ctx, "POST", args[0], URI.encode_www_form([URI.Pair(name: "message[body]", value: args[1] + padding)]))
end

# The form of the page that was just got, found by the `action` that it names, and posted to that action as the page
# wrote it: a form that the page does not have fails the step, so the page is what makes the post possible.
def submit_page_form(ctx: BDD.Context, args: List[String]) -> BDD.Context
  marker = "<form method=\"post\" action=\"#{args[0]}\">"
  page = last_reply(ctx).body
  if not page.include?(marker)
    return BDD.assert(ctx, false, "the page has no form that posts to #{args[0]}: #{page}")
  end

  return send(ctx, "POST", args[0], "")
end

# The form of the join page, whose action holds the code that the page was got with: the fields of the table are posted
# to the action that the page names.
def submit_join_form(ctx: BDD.Context, args: List[String]) -> BDD.Context
  action = text_after(last_reply(ctx).body, "<form method=\"post\" action=\"", "\"")
  if action.none? or not action.unwrap!.start_with?("/join/")
    return BDD.assert(ctx, false, "the page has no join form: #{last_reply(ctx).body}")
  end

  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  return send(ctx, "POST", action.unwrap!, URI.encode_www_form(pairs))
end

# The path of the join link that the page shows (an administrator's people page), whatever address it starts with.
def join_link_of(ctx: BDD.Context) -> Optional[String]
  link = text_after(last_reply(ctx).body, "<code id=\"join-link\">", "<")
  if link.none?
    return none
  end

  start = link.unwrap!.index_of("/join/")
  if start.none?
    return none
  end

  return some(link.unwrap!.slice(start.unwrap!, link.unwrap!.length - start.unwrap!))
end

def remember_join_link(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = join_link_of(ctx)
  if path.none?
    return BDD.assert(ctx, false, "the page has no join link: #{last_reply(ctx).body}")
  end

  return BDD.set(ctx, JOIN_LINK, JSON.from(path.unwrap!))
end

def remembered_join_link(ctx: BDD.Context) -> String
  return JSON.string(BDD.get(ctx, JOIN_LINK).unwrap!).unwrap!
end

def get_remembered_join_link(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, "GET", remembered_join_link(ctx), "")
end

def post_to_remembered_join_link(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  return send(ctx, "POST", remembered_join_link(ctx), URI.encode_www_form(pairs))
end

def join_link_changed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = join_link_of(ctx)
  return BDD.assert(
    ctx,
    path.some? and path.unwrap! != remembered_join_link(ctx),
    "the join link of the page is #{path}, the remembered one is #{remembered_join_link(ctx)}",
  )
end

# The text of `text` between the first `start` and the next `stop` after it.
def text_after(text: String, start: String, stop: String) -> Optional[String]
  at = text.index_of(start)
  if at.none?
    return none
  end

  rest = text.slice(at.unwrap! + start.length, text.length - at.unwrap! - start.length)
  end_at = rest.index_of(stop)
  if end_at.none?
    return none
  end

  return some(rest.slice(0, end_at.unwrap!))
end

def post_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, "POST", args[0], "")
end

# The method that a browser form cannot send, with no body.
def delete_to(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return send(ctx, "DELETE", args[0], "")
end

# A new session: the browser forgets its cookies and signs in through the form, as a person does. The first admin has
# its own password and the members that `a member ... exists` makes share another.
def sign_in_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  password = MEMBER_PASSWORD
  if args[0] == ADMIN_EMAIL
    password = ADMIN_PASSWORD
  end

  form = URI.encode_www_form([
    URI.Pair(name: "email_address", value: args[0]),
    URI.Pair(name: "password", value: password),
  ])

  made = send(forget_cookies(ctx, []), "POST", "/session", form)
  return BDD.assert(
    made,
    last_reply(made).status == 302,
    "signing in as #{args[0]} answered #{last_reply(made).status}",
  )
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
  state = browser(ctx)
  started = Time.monotonic_ms()
  response = perform(port_of(ctx), state, method, path, body)
  elapsed = Time.monotonic_ms() - started
  if not response.ok?
    return BDD.assert(ctx, false, "#{method} #{path} failed: #{response.message}")
  end

  kept = state.with(cookies: cookies_after(state.cookies, response.unwrap!))
  reply = reply_of(response.unwrap!, elapsed, path)
  return BDD.set(BDD.set(ctx, REPLY, JSON.from(reply)), BROWSER, JSON.from(kept))
end

# The same form, sent `args[1]` times in parallel by the browser as it is. The statuses are kept for the steps that
# read them; the answers themselves (and their cookies) are not, since each request is its own.
def post_form_at_once(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  return post_at_once(ctx, args[0], URI.encode_www_form(pairs), args[1].to_i!)
end

def post_answer(port: Int, state: Browser, path: String, body: String) -> Result[Answer]
  response = try perform(port, state, "POST", path, body)
  retries = HTTP.header_values(response.headers, "retry-after")
  text = String.from_bytes(response.body).unwrap_or("")
  return ok(Answer(status: response.status, retry_after: retries.join(","), body: text))
end

def perform(port: Int, state: Browser, method: String, path: String, body: String) -> Result[HttpResponse]
  headers = state.headers.keys.map do |name| Header(name: name, value: state.headers.get(name, "")) end
  if not state.cookies.empty?
    pairs = state.cookies.keys.map do |name| "#{name}=#{state.cookies.get(name, "")}" end
    headers = headers.push(Header(name: "cookie", value: pairs.join("; ")))
  end

  if method == "POST"
    headers = headers.push(Header(name: "content-type", value: FORM_TYPE))
  end

  client = try HTTP.client()
  response = HTTP.request(client, method, "http://127.0.0.1:#{port}#{path}", body.bytes, headers)
  HTTP.close_client(client)
  return response
end

def port_of(ctx: BDD.Context) -> Int
  return JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
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

def reply_of(response: HttpResponse, elapsed_ms: Int, path: String) -> Reply
  start: Map[String, String] = {}
  headers = response.headers.reduce(start) do |acc, header| acc.put(header.name.downcase, header.value) end
  body = String.from_bytes(response.body).unwrap_or("")
  return Reply(
    status: response.status,
    headers: headers,
    body: body,
    elapsed_ms: elapsed_ms,
    path: path,
    size: response.body.size,
    sha256: Digest.sha256_hexdigest(response.body),
    head: Digest.hexencode(response.body.take(HEAD_BYTES)),
  )
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

def remember_answer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, REMEMBERED, JSON.from(last_reply(ctx)))
end

# The status and the body, which is what a visitor sees: the page of a reset request must not tell an email that has
# an account from one that has none.
def answer_is_remembered(ctx: BDD.Context, args: List[String]) -> BDD.Context
  before = JSON.decode(BDD.get(ctx, REMEMBERED).unwrap!, Reply).unwrap!
  now = last_reply(ctx)
  return BDD.assert(ctx, before.status == now.status and before.body == now.body, "the answers differ: #{now.body}")
end

# A page that is made again draws a new id for its form, so a page that was kept and one that was made differ.
def answer_is_not_remembered(ctx: BDD.Context, args: List[String]) -> BDD.Context
  before = JSON.decode(BDD.get(ctx, REMEMBERED).unwrap!, Reply).unwrap!
  return BDD.assert(ctx, before.body != last_reply(ctx).body, "the answer is the one that was remembered")
end

# What a browser does with a validator: it sends the `ETag` of the answer back as `If-None-Match`.
def send_header_of_answer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  value = last_reply(ctx).headers.get(args[1].downcase, "")
  if value.empty?
    return BDD.assert(ctx, false, "the answer has no header #{args[1]}: #{last_reply(ctx).headers}")
  end

  return set_header(ctx, [args[0], value])
end

# The Turbo Stream that a post answered carries the message in its `<template>`; the page that reads the same message
# back must write the same markup, the time and the author included.
def body_has_remembered_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  before = JSON.decode(BDD.get(ctx, REMEMBERED).unwrap!, Reply).unwrap!
  message = text_after(before.body, "<template>", "</template>")
  if message.none?
    return BDD.assert(ctx, false, "the remembered answer has no template: #{before.body}")
  end

  body = last_reply(ctx).body
  return BDD.assert(ctx, body.include?(message.unwrap!), "the message #{message.unwrap!} is not in #{body}")
end

def remember_thread(ctx: BDD.Context, args: List[String]) -> BDD.Context
  thread = text_after(last_reply(ctx).body, THREAD_START, THREAD_END)
  if thread.none?
    return BDD.assert(ctx, false, "the page has no thread of messages: #{last_reply(ctx).body}")
  end

  return BDD.set(ctx, THREAD, JSON.from(thread.unwrap!))
end

def thread_is_remembered(ctx: BDD.Context, args: List[String]) -> BDD.Context
  before = JSON.string(BDD.get(ctx, THREAD).unwrap!).unwrap!
  now = text_after(last_reply(ctx).body, THREAD_START, THREAD_END)
  return BDD.assert(ctx, now == some(before), "the messages differ: #{now.unwrap_or("none")} and #{before}")
end

def answer_was_quick(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.elapsed_ms < args[0].to_i!, "the answer took #{reply.elapsed_ms} milliseconds")
end

def status_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.status == args[0].to_i!, "the status is #{reply.status}")
end

def header_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.headers.get(args[0].downcase, "") == args[1], "the headers are #{reply.headers}")
end

def header_is_number_between(ctx: BDD.Context, args: List[String]) -> BDD.Context
  value = last_reply(ctx).headers.get(args[0].downcase, "")
  number = value.to_i
  return BDD.assert(
    ctx,
    number.ok? and number.unwrap! >= args[1].to_i! and number.unwrap! <= args[2].to_i!,
    "the header #{args[0]} is #{value.inspect}, not a number from #{args[1]} to #{args[2]}",
  )
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

def body_contains_times(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = last_reply(ctx).body
  found = body.split(args[0]).size - 1
  return BDD.assert(ctx, found == args[1].to_i!, "the body has #{found} of #{args[0]}: #{body}")
end

def body_starts_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = last_reply(ctx).body
  return BDD.assert(ctx, body.start_with?(args[0]), "the body is #{body}")
end

# The end of the text without the white space after it, as the benchmark reads it.
def body_ends_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = last_reply(ctx).body
  return BDD.assert(ctx, body.strip.end_with?(args[0]), "the body is #{body}")
end

def body_is_webp(ctx: BDD.Context, args: List[String]) -> BDD.Context
  head = last_reply(ctx).head
  is_webp = head.length == HEAD_BYTES * 2 and head.start_with?(WEBP_MAGIC_START) and head.end_with?(WEBP_MAGIC_END)
  return BDD.assert(ctx, is_webp, "the body starts with the bytes #{head}, not those of a WebP")
end

# The link that the page of the last answer has to its stylesheet, as the benchmark reads it: `href="/assets/....css"`.
def stylesheet_link(ctx: BDD.Context) -> Optional[String]
  return text_after(last_reply(ctx).body, "<link rel=\"stylesheet\" href=\"", "\"")
end

def get_stylesheet(ctx: BDD.Context, args: List[String]) -> BDD.Context
  link = stylesheet_link(ctx)
  if link.none?
    return BDD.assert(ctx, false, "the page has no link to a stylesheet: #{last_reply(ctx).body}")
  end

  return send(ctx, "GET", link.unwrap!, "")
end

# The script that the room page links, a fingerprinted file of the assets folder like the stylesheet.
def get_script(ctx: BDD.Context, args: List[String]) -> BDD.Context
  link = text_after(last_reply(ctx).body, "<script src=\"", "\"")
  if link.none?
    return BDD.assert(ctx, false, "the page has no script: #{last_reply(ctx).body}")
  end

  return send(ctx, "GET", link.unwrap!, "")
end

# `campfire-DIGEST.css` or `.js`: the digest is what is between the last `-` and the extension, and has to be the start
# of the SHA-256 of the file that the name stands for.
def body_has_digest(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  name = reply.path.split("/").last
  dash = name.split("-").last
  extension = ".#{dash.split(".").last}"
  digest = dash.slice(0, dash.length - extension.length)
  return BDD.assert(
    ctx,
    not digest.empty? and name.start_with?("campfire-") and reply.sha256.start_with?(digest),
    "the name #{name} does not hold the start of the SHA-256 of its body, #{reply.sha256}",
  )
end

def body_shows_before(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = last_reply(ctx).body
  first = body.index_of(args[0])
  second = body.index_of(args[1])
  return BDD.assert(ctx, first.some? and second.some? and first.unwrap! < second.unwrap!, "the body is #{body}")
end

def header_lacks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  value = last_reply(ctx).headers.get(args[0].downcase, "")
  return BDD.assert(ctx, not value.include?(args[1]), "the header #{args[0]} is #{value.inspect}")
end

def answers_of(ctx: BDD.Context) -> List[Answer]
  return JSON.decode(BDD.get(ctx, STATUSES).unwrap!, Answers).unwrap!.values
end

def statuses_of(ctx: BDD.Context) -> List[Int]
  return answers_of(ctx).map do |answer| answer.status end
end

# `args[0]` is a list of statuses separated by commas, such as "302, 503".
def each_status_is_one_of(ctx: BDD.Context, args: List[String]) -> BDD.Context
  allowed = args[0].split(",").map do |text| text.strip.to_i! end
  statuses = statuses_of(ctx)
  stray = statuses.select do |status| not allowed.include?(status) end
  return BDD.assert(ctx, stray.empty?, "the statuses are #{statuses}, and only #{allowed} may be")
end

def some_status_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  statuses = statuses_of(ctx)
  return BDD.assert(ctx, statuses.include?(args[0].to_i!), "the statuses are #{statuses}")
end

def count_statuses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  statuses = statuses_of(ctx)
  found = statuses.select do |status| status == args[1].to_i! end
  return BDD.assert(ctx, found.size == args[0].to_i!, "the statuses are #{statuses}")
end

def each_503_body_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  refused = answers_of(ctx).select do |answer| answer.status == 503 end
  wrong = refused.select do |answer| not answer.body.include?(args[0]) end
  return BDD.assert(
    ctx,
    not refused.empty? and wrong.empty?,
    "the 503 answers are #{refused.size}, #{wrong.size} lack it",
  )
end

def each_503_says_retry_after(ctx: BDD.Context, args: List[String]) -> BDD.Context
  refused = answers_of(ctx).select do |answer| answer.status == 503 end
  wrong = refused.select do |answer| answer.retry_after != args[0] end
  seen = wrong.map do |answer| answer.retry_after end
  return BDD.assert(ctx, wrong.empty?, "a 503 has the retry-after #{seen}, not #{args[0].inspect}")
end
