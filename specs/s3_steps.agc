## The steps of the S3 service. The bucket is `fixtures/s3_stub.py` (Python's standard library, an S3 server apart from
## the app's client, which checks the signature of every request), a child process that a service keeps. The steps
## play the browser: they ask the app for a direct upload, put the bytes at the URLs that it answers, and post the
## message that names the blob.

import BDD from "std/bdd"
import HTTP from "std/http"
import URI from "std/uri"
import HttpSteps from "http_steps"

## The steps of the S3 server and of the direct uploads.
def steps() -> List[BDD.Step]
  [
    BDD.step("an S3 server", &start_stub),
    BDD.step("I ask for a direct upload of {string} of the type {string} and {int} bytes", &ask),
    BDD.step("the direct upload is refused as {string}", &was_refused),
    BDD.step("the direct upload has {int} parts", &has_parts),
    BDD.step("the browser puts a file of {int} bytes that starts with {string} at the URLs of the answer", &put_file),
    BDD.step("the S3 server refuses the part {int}", &refuses_part),
    BDD.step("the browser puts the parts of a file of {int} bytes, and the part {int} is refused", &put_until_refused),
    BDD.step("the direct upload is answered with the status {int}", &answered_with),
    BDD.step("I post to {string} the message with the direct upload of the answer", &post_message),
    BDD.step("I ask for a direct upload and put {int} bytes that start with {string}", &ask_and_put),
    BDD.step("the location of the answer gives {int} bytes of the type {string}", &location_gives),
    BDD.step("the S3 server saw a DELETE of the object of the direct upload", &saw_delete),
    BDD.step("the S3 server saw a DELETE of the object of the direct upload within {int} seconds", &saw_delete_within),
  ]
end

## The environment that makes the app use the S3 server of the scenario; none when there is no such server.
def app_environment(ctx: BDD.Context) -> Map[String, String]
  return {} if not BDD.get(ctx, ENDPOINT).ok?

  {
    "CAMPFIRE_STORAGE_SERVICE": "s3",
    "CAMPFIRE_S3_ENDPOINT": text_of(ctx, ENDPOINT),
    "CAMPFIRE_S3_REGION": text_of(ctx, REGION),
    "CAMPFIRE_S3_BUCKET": text_of(ctx, BUCKET_KEY),
    "CAMPFIRE_S3_ACCESS_KEY_ID": text_of(ctx, ACCESS),
    "CAMPFIRE_S3_SECRET_ACCESS_KEY": text_of(ctx, SECRET),
    "CAMPFIRE_S3_KEY_PREFIX": text_of(ctx, PREFIX),
  }
end

private

STUB = "specs/fixtures/s3_stub.py"
SERVICE = "s3_stub"
ENDPOINT = "s3_endpoint"
REGION = "s3_region"
BUCKET_KEY = "s3_bucket"
ACCESS = "s3_access_key"
SECRET = "s3_secret_key"
PREFIX = "s3_prefix"
EXTERNAL = "s3_external"
ANSWER = "direct_answer"
STATUS = "direct_status"
BUCKET = "campfire-files"
ACCESS_KEY = "fake-access-key"
SECRET_KEY = "fake-secret-key"
STARTUP_MS = 10_000
MEGABYTE = 1_048_576
CLIENT_MAX_BODY = 67_108_864

struct Wanted
  filename: String
  content_type: String
  byte_size: Int
end

struct Asked
  blob: Wanted
end

struct PartUrl
  number: Int
  url: String
end

# What the app answers to a direct upload.
struct Created
  key: String
  url: String
  part_bytes: Int
  parts: List[PartUrl]
end

def endpoint(ctx: BDD.Context) -> String = text_of(ctx, ENDPOINT)

def external?(ctx: BDD.Context) -> Bool = BDD.get(ctx, EXTERNAL).ok?

def text_of(ctx: BDD.Context, name: String) -> String
  case BDD.get(ctx, name)
    ok(value) -> JSON.string(value).unwrap_or("")
    error(_) -> ""
  end
end

# With `S3_TEST_ENDPOINT`, `S3_TEST_REGION`, `S3_TEST_BUCKET`, `S3_TEST_ACCESS_KEY` and `S3_TEST_SECRET_KEY` set, the
# specs run on that server (rustfs, MinIO, AWS S3) in keys under a prefix of their own, which they do not delete; the
# scenarios that read what the stand-in saw skip.
def start_stub(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return use_external(ctx) if System.env("S3_TEST_ENDPOINT").ok?

  stub = ["-I", STUB, "--bucket", BUCKET, "--access-key", ACCESS_KEY, "--secret-key", SECRET_KEY]
  started = Process.spawn_captured("python3", stub, Process.Options(timeout_ms: 600_000))
  return BDD.assert(ctx, false, "cannot start the S3 server: #{started.message}") if not started.ok?

  peer = started.unwrap!
  line = Process.read_line(peer, STARTUP_MS)
  if not line.ok? or not line.unwrap!.start_with?("port ")
    return BDD.assert(ctx, false, "the S3 server did not start: #{line.message}")
  end

  kept = BDD.keep(ctx, SERVICE) do |_request| ok(JSON.from("")) end
  port = line.unwrap!.slice(5, line.unwrap!.length - 5).to_i!
  configured(kept, "http://127.0.0.1:#{port}", BUCKET, ACCESS_KEY, SECRET_KEY, "")
end

def use_external(ctx: BDD.Context) -> BDD.Context
  configured(
    BDD.set(ctx, EXTERNAL, JSON.from(true)),
    System.env("S3_TEST_ENDPOINT").unwrap_or(""),
    System.env("S3_TEST_BUCKET").unwrap_or(""),
    System.env("S3_TEST_ACCESS_KEY").unwrap_or(""),
    System.env("S3_TEST_SECRET_KEY").unwrap_or(""),
    "spec-#{OpenSSL.Random.hex(6)}/",
  )
end

def configured(
  ctx: BDD.Context,
  endpoint: String,
  bucket: String,
  access: String,
  secret: String,
  prefix: String,
) -> BDD.Context
  region = System.env("S3_TEST_REGION").unwrap_or("us-east-1")
  settings = [
    [ENDPOINT, endpoint],
    [BUCKET_KEY, bucket],
    [ACCESS, access],
    [SECRET, secret],
    [PREFIX, prefix],
    [REGION, region],
  ]

  settings.reduce(ctx) do |acc, pair| BDD.set(acc, pair[0], JSON.from(pair[1])) end
end

# What a browser of the page sends: the cookies of its session, and a JSON body.
def ask(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = JSON.encode(Asked(blob: Wanted(filename: args[0], content_type: args[1], byte_size: args[2].to_i!)))
  headers = [
    HTTP.Header(name: "content-type", value: "application/json"),
    HTTP.Header(name: "cookie", value: HttpSteps.cookie_header(ctx)),
  ]

  response = request(
    "POST",
    "http://127.0.0.1:#{HttpSteps.port_of(ctx)}/rails/active_storage/direct_uploads",
    body.bytes,
    headers,
  )

  return BDD.assert(ctx, false, "the direct upload failed: #{response.message}") if not response.ok?

  text = String.from_bytes(response.unwrap!.body).unwrap_or("")
  BDD.set(BDD.set(ctx, ANSWER, JSON.from(text)), STATUS, JSON.from(response.unwrap!.status))
end

def answered_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  status = JSON.int(BDD.get(ctx, STATUS).unwrap!).unwrap!
  BDD.assert(ctx, status == args[0].to_i!, "answered #{status} #{text_of(ctx, ANSWER)}")
end

# The stand-in answers 500 to this part of every upload from now on (a door of the stand-in).
def refuses_part(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.skip(ctx, "the stand-in has the door") if external?(ctx)

  response = request("PUT", "#{endpoint(ctx)}/__stub/fail_part/#{args[0]}", "".bytes, [])
  BDD.assert(ctx, response.ok? and response.unwrap!.status == 200, "the door did not open")
end

# The browser puts the parts in order and stops at the first that fails, as the script does.
def put_until_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  plan = created(ctx)
  file = file_bytes(args[0].to_i!, "00")
  for part in plan.parts
    first = (part.number - 1) * plan.part_bytes
    count = [plan.part_bytes, file.length - first].min.unwrap!
    response = request("PUT", part.url, file.slice(first, count), [])
    return BDD.assert(ctx, false, "the put failed: #{response.message}") if not response.ok?

    if part.number == args[1].to_i!
      return BDD.assert(ctx, response.unwrap!.status == 500, "the put answered #{response.unwrap!.status}")
    end

    if response.unwrap!.status != 200
      return BDD.assert(ctx, false, "the part #{part.number} answered #{response.unwrap!.status}")
    end
  end

  BDD.assert(ctx, false, "no part was refused")
end

def was_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  status = JSON.int(BDD.get(ctx, STATUS).unwrap!).unwrap!
  BDD.assert(
    ctx,
    status == 422 and text_of(ctx, ANSWER).include?(args[0]),
    "answered #{status} #{text_of(ctx, ANSWER)}",
  )
end

def created(ctx: BDD.Context) -> Created = JSON.decode(JSON.parse(text_of(ctx, ANSWER)).unwrap!, Created).unwrap!

def has_parts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, created(ctx).parts.length == args[0].to_i!, "the answer has #{created(ctx).parts.length} parts")
end

# The bytes of a file: `start` (hex), then "x" up to `size`.
def file_bytes(size: Int, start: String) -> Bytes
  head = OpenSSL.Digest.hexdecode(start).unwrap!
  chunk = List.repeat("x", MEGABYTE).join("").bytes
  rest = size - head.length
  pieces = List.repeat(chunk, rest / MEGABYTE).push(List.repeat("x", rest % MEGABYTE).join("").bytes)
  Bytes.concat([head] + pieces)
end

# Puts the file at the URL of the answer, or its parts at the URLs of its parts, as the script of the page does.
def put_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  plan = created(ctx)
  file = file_bytes(args[0].to_i!, args[1])
  return put(ctx, plan.url, file) if plan.parts.empty?

  done = ctx
  for part in plan.parts
    first = (part.number - 1) * plan.part_bytes
    count = [plan.part_bytes, file.length - first].min.unwrap!
    done = put(done, part.url, file.slice(first, count))
  end

  done
end

def put(ctx: BDD.Context, url: String, body: Bytes) -> BDD.Context
  response = request("PUT", url, body, [])
  return BDD.assert(ctx, false, "the put failed: #{response.message}") if not response.ok?

  BDD.assert(ctx, response.unwrap!.status == 200, "the put answered #{response.unwrap!.status}")
end

def ask_and_put(ctx: BDD.Context, args: List[String]) -> BDD.Context
  asked = ask(ctx, ["file.bin", "application/octet-stream", args[0]])
  put_file(asked, [args[0], args[1]])
end

# The message that names the blob, as a form with the key and no file.
def post_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  form = URI.encode_www_form([URI.Pair(name: "message[direct_upload]", value: created(ctx).key)])
  HttpSteps.post(ctx, args[0], form)
end

# The redirect that the last answer was, fetched as the browser does, with no cookie: the signature is the credential.
def location_gives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  response = request("GET", HttpSteps.last_header(ctx, "location"), "".bytes, [])
  return BDD.assert(ctx, false, "the location failed: #{response.message}") if not response.ok?

  got = response.unwrap!
  type = HTTP.header_values(got.headers, "content-type").join(",")
  BDD.assert(
    ctx,
    got.status == 200 and got.body.length == args[0].to_i! and type == args[1],
    "the location gave #{got.status}, #{got.body.length} bytes of #{type}",
  )
end

def request(method: String, url: String, body: Bytes, headers: List[HTTP.Header]) -> Result[HTTP.Response]
  client = try HTTP.client(HTTP.ClientOptions(max_body_bytes: CLIENT_MAX_BODY))
  response = HTTP.request(client, method, url, body, headers)
  HTTP.close_client(client)
  response
end

def requests_seen(ctx: BDD.Context) -> List[String]
  seen = request("GET", "#{endpoint(ctx)}/__stub/requests", "".bytes, [])
  return [] if not seen.ok?

  String.from_bytes(seen.unwrap!.body).unwrap_or("").split("\n")
end

def deleted?(ctx: BDD.Context) -> Bool
  key = created(ctx).key
  requests_seen(ctx).any? { |line|
    line.start_with?("DELETE") and line.include?(key) and not line.include?("uploadId")
  }
end

def saw_delete(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.skip(ctx, "the stand-in tells what it saw") if external?(ctx)

  BDD.assert(ctx, deleted?(ctx), "the S3 server saw no DELETE of #{created(ctx).key}")
end

# A task of the app deletes the objects that nobody posted, some time after it starts.
def saw_delete_within(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.skip(ctx, "the stand-in tells what it saw") if external?(ctx)

  for _ in 1..(args[0].to_i! * 5)
    return BDD.assert(ctx, true, "") if deleted?(ctx)

    Task.sleep(200)
  end

  BDD.assert(ctx, false, "the S3 server saw no DELETE of #{created(ctx).key}")
end
