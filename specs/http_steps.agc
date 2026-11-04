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
REMEMBERED = "remembered_reply"
STATUSES = "statuses"
ALL_AT_ONCE_MS = 60_000
BROWSER = "browser"
FORM_TYPE = "application/x-www-form-urlencoded"

struct Reply
  status: Int
  headers: Map[String, String]
  body: String
  elapsed_ms: Int
end

# What a parallel request answered: the status, and the `Retry-After` header ("" when it has none).
struct Answer
  status: Int
  retry_after: String
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
    BDD.step("I post nothing to {string}", &post_nothing),
    BDD.step("the first admin exists", &first_admin),
    BDD.step("I remember the answer", &remember_answer),
    BDD.step("the answer is the one that I remembered", &answer_is_remembered),
    BDD.step("the answer came within {int} milliseconds", &answer_was_quick),
    BDD.step("the status is {int}", &status_is),
    BDD.step("the header {string} is {string}", &header_is),
    BDD.step("the header {string} contains {string}", &header_contains),
    BDD.step("the header {string} does not contain {string}", &header_lacks),
    BDD.step("each status is one of {string}", &each_status_is_one_of),
    BDD.step("at least one status is {int}", &some_status_is),
    BDD.step("each 503 answer has the header \"retry-after\" {string}", &each_503_says_retry_after),
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

## Posts `body`, a form that a step encoded, to `path`.
export def post(ctx: BDD.Context, path: String, body: String) -> BDD.Context
  return send(ctx, "POST", path, body)
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
  state = browser(ctx)
  started = Time.monotonic_ms()
  response = perform(port_of(ctx), state, method, path, body)
  elapsed = Time.monotonic_ms() - started
  if not response.ok?
    return BDD.assert(ctx, false, "#{method} #{path} failed: #{response.message}")
  end

  kept = state.with(cookies: cookies_after(state.cookies, response.unwrap!))
  reply = reply_of(response.unwrap!, elapsed)
  return BDD.set(BDD.set(ctx, REPLY, JSON.from(reply)), BROWSER, JSON.from(kept))
end

# The same form, sent `args[1]` times in parallel by the browser as it is. The statuses are kept for the steps that
# read them; the answers themselves (and their cookies) are not, since each request is its own.
def post_form_at_once(ctx: BDD.Context, args: List[String]) -> BDD.Context
  pairs = BDD.table(ctx).map do |row| URI.Pair(name: row[0], value: row[1]) end
  body = URI.encode_www_form(pairs)
  port = port_of(ctx)
  state = browser(ctx)
  count = args[1].to_i!
  attempts = (1..count).to_a
  answers = Task.map(attempts, count, ALL_AT_ONCE_MS) do |_| post_answer(port, state, args[0], body) end
  failed = answers.select do |answer| not answer.ok? end
  if not failed.empty?
    return BDD.assert(ctx, false, "a request failed: #{failed[0].message}")
  end

  return BDD.set(ctx, STATUSES, JSON.from(Answers(values: answers.map do |answer| answer.unwrap! end)))
end

def post_answer(port: Int, state: Browser, path: String, body: String) -> Result[Answer]
  response = try perform(port, state, "POST", path, body)
  retries = HTTP.header_values(response.headers, "retry-after")
  return ok(Answer(status: response.status, retry_after: retries.join(",")))
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

def reply_of(response: HttpResponse, elapsed_ms: Int) -> Reply
  start: Map[String, String] = {}
  headers = response.headers.reduce(start) do |acc, header| acc.put(header.name.downcase, header.value) end
  body = String.from_bytes(response.body).unwrap_or("")
  return Reply(status: response.status, headers: headers, body: body, elapsed_ms: elapsed_ms)
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

def each_503_says_retry_after(ctx: BDD.Context, args: List[String]) -> BDD.Context
  refused = answers_of(ctx).select do |answer| answer.status == 503 end
  wrong = refused.select do |answer| answer.retry_after != args[0] end
  seen = wrong.map do |answer| answer.retry_after end
  return BDD.assert(ctx, wrong.empty?, "a 503 has the retry-after #{seen}, not #{args[0].inspect}")
end
