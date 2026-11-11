import Bond from "pkg/bond/bond"
import HTTP from "std/http"
import Testing from "pkg/bond/testing"
import Web from "../src/campfire_web/web"

# A handler that names its own policy with the name in the casing it likes: Bond keeps the name as written.
def own(conn: Bond.Conn) -> Result[Bond.Conn]
  ok(Bond.header(Bond.html(conn, 200, "<p>a</p>"), "Cache-Control", "no-store"))
end

def plain(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.html(conn, 200, "<p>a</p>"))

def moved(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.redirect(conn, "/plain"))

def not_changed(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.html(conn, 200, "<p>a</p>").with(status: 304))

def json(conn: Bond.Conn) -> Result[Bond.Conn] = ok(Bond.text(conn, 200, "x"))

def main() -> Void
  Test.run([
    Test.test(
      "revalidate keeps a Cache-Control of the handler in any casing, and leaves a 304 and plain text alone",
    ) do
      app = (
        Bond.app()
        |> Bond.get("/own", &own)
        |> Bond.get("/plain", &plain)
        |> Bond.get("/moved", &moved)
        |> Bond.get("/same", &not_changed)
        |> Bond.get("/text", &json)
        |> Bond.after() do |conn| Web.revalidate(conn) end
      )

      kept = Testing.request(app, "GET", "/own")
      try Test.eq(HTTP.header_values(kept.headers, "cache-control"), ["no-store"])
      given = Testing.request(app, "GET", "/plain")
      try Test.eq(HTTP.header_values(given.headers, "cache-control"), ["max-age=0, private, must-revalidate"])
      redirected = Testing.request(app, "GET", "/moved")
      try Test.eq(HTTP.header_values(redirected.headers, "cache-control"), ["max-age=0, private, must-revalidate"])
      not_modified = Testing.request(app, "GET", "/same")
      try Test.eq(not_modified.status, 304)
      try Test.eq(HTTP.header_values(not_modified.headers, "cache-control"), [])
      text = Testing.request(app, "GET", "/text")
      return Test.eq(HTTP.header_values(text.headers, "cache-control"), [])
    end,
  ])
end
