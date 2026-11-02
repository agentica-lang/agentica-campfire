## The steps of the features. The program of `fixtures/server.agc` serves the app on 127.0.0.1 and a free port, and the
## steps talk to it with the HTTP client of `std/http`.

import BDD from "std/bdd"
import HTTP from "std/http"

PORT = "port"
REPLY = "reply"
SOCKET_MS = 5_000

struct Reply
  status: Int
  headers: Map[String, String]
  body: String
end

def main() -> Void
  BDD.run([
    BDD.step("the app listens on a free port", &start_app),
    BDD.step("I get {string}", &get),
    BDD.step("the status is {int}", &status_is),
    BDD.step("the header {string} is {string}", &header_is),
    BDD.step("the body is {string}", &body_is),
    BDD.step("the body contains {string}", &body_contains),
  ])
end

# The first line of the program is `listening on http://127.0.0.1:PORT`.
def start_app(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = BDD.given_program(ctx, "fixtures/server.agc")
  line = BDD.read_line(started, SOCKET_MS).unwrap!
  port = line.split(":").last.to_i!
  return BDD.set(started, PORT, JSON.from(port))
end

def get(ctx: BDD.Context, args: List[String]) -> BDD.Context
  port = JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
  client = HTTP.client().unwrap!
  response = HTTP.get(client, "http://127.0.0.1:#{port}#{args[0]}").unwrap!
  HTTP.close_client(client)
  return BDD.set(ctx, REPLY, JSON.from(reply_of(response)))
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

def status_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.status == args[0].to_i!, "the status is #{reply.status}")
end

def header_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.headers.get(args[0].downcase, "") == args[1], "the headers are #{reply.headers}")
end

def body_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body == args[0], "the body is #{reply.body}")
end

def body_contains(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = last_reply(ctx)
  return BDD.assert(ctx, reply.body.include?(args[0]), "the body is #{reply.body}")
end
