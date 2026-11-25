## The S3 service of Active Storage, next to the Disk service: where the files of a message go when
## `CAMPFIRE_STORAGE_SERVICE` is `s3`. The server never reads the bytes of an upload. It makes the blob row and signs
## the URLs, the browser puts the file in the bucket (in parts of `PART_BYTES` above one part), and a download is a
## redirect to a signed `GET` that lasts `DOWNLOAD_SECONDS`. The keys are those of Active Storage (28 characters of base
## 36) under an optional prefix.

import S3 from "pkg/s3/s3"

## The blobs that this service makes have this `service_name`; a blob row of Rails' Disk service says `local`.
SERVICE_NAME = "s3"

## The size of a part: a file up to this size is one `PUT`, a bigger one goes in parts (S3 wants 5 MiB or more but the
## last), so a file of the largest size of `Config.MAX_S3_ATTACHMENT_MB` needs 320 of them.
PART_BYTES = 16_777_216

## How long the URLs of an upload last: the whole upload of a big file on a slow line, not one request.
UPLOAD_SECONDS = 21_600

## How long the link of a download lasts. A browser follows the redirect at once, so it only has to outlive that.
DOWNLOAD_SECONDS = 60

## The text of the `CAMPFIRE_STORAGE_SERVICE` and `CAMPFIRE_S3_*` variables, each "" when not set. It holds the secret
## key, so it is as secret as the session secret.
struct Env
  service: String = ""
  endpoint: String = ""
  region: String = ""
  bucket: String = ""
  access_key_id: String = ""
  secret_access_key: String = ""
  addressing: String = ""
  key_prefix: String = ""
end

## The service that the app uses: the client of the package and what it signs for.
struct Store
  client: S3.Client
  prefix: String
end

## One part of a big upload: its number and the URL that takes it.
struct PartUrl
  number: Int
  url: String
end

## What the browser needs to upload a file. A file that fits one part has `url`; a bigger one has `part_bytes` and the
## `parts`, which hold a URL each (the last part is the rest of the file).
struct Plan
  url: String = ""
  upload_id: String = ""
  part_bytes: Int = 0
  parts: List[PartUrl] = []
end

## What the `metadata` of a blob says while its upload is not posted: the person who started it, and the id of its
## multipart upload ("" for a file in one `PUT`).
struct Pending
  person: Int
  upload_id: String = ""
end

## The store of the variables, `none` for the Disk service. An `error` that names the variable for a service that is
## not `disk` or `s3`, and for an `s3` that lacks its endpoint (`http://` or `https://`), bucket or keys, has an
## addressing that is not `path` or `virtual`, or a prefix that starts with `/`, or that the package refuses. A region
## left out is `us-east-1`.
def open(env: Env) -> Result[Optional[Store]]
  return ok(none) if env.service == "" or env.service == "disk"

  return error("CAMPFIRE_STORAGE_SERVICE must be disk or s3, not #{env.service.inspect}") if env.service != "s3"

  endpoint = env.endpoint.strip
  if not (endpoint.start_with?("http://") or endpoint.start_with?("https://"))
    return error("CAMPFIRE_S3_ENDPOINT must start with http:// or https://, not #{env.endpoint.inspect}")
  end

  return error("CAMPFIRE_S3_BUCKET is empty") if env.bucket.strip.empty?

  if env.access_key_id.empty? or env.secret_access_key.empty?
    return error("CAMPFIRE_S3_ACCESS_KEY_ID and CAMPFIRE_S3_SECRET_ACCESS_KEY are both required")
  end

  addressing = S3.Addressing.Path
  if env.addressing == "virtual"
    addressing = S3.Addressing.Virtual
  elsif env.addressing != "" and env.addressing != "path"
    return error("CAMPFIRE_S3_ADDRESSING must be path or virtual, not #{env.addressing.inspect}")
  end

  return error("CAMPFIRE_S3_KEY_PREFIX must not start with /") if env.key_prefix.start_with?("/")

  region = env.region.strip
  if region.empty?
    region = "us-east-1"
  end

  config = S3.Config(
    endpoint: endpoint,
    region: region,
    access_key: env.access_key_id,
    secret_key: env.secret_access_key,
    bucket: env.bucket.strip,
    addressing: addressing,
  )

  client = S3.client(config)
  return error("CAMPFIRE_S3_*: #{client.message}") if not client.ok?

  ok(some(Store(client: client.unwrap!, prefix: env.key_prefix)))
end

## Closes the connections of the store.
def close(store: Store) -> Void
  S3.close(store.client)
end

## The person that the `metadata` of a pending upload names, 0 for any other text.
def person_of(metadata: String) -> Int
  parsed = JSON.parse(metadata)
  return 0 if not parsed.ok?

  found = JSON.decode(parsed.unwrap!, Pending)
  return 0 if not found.ok?

  found.unwrap!.person
end

## The upload id that the `metadata` JSON of a blob holds while its multipart upload is not completed, "" for none.
def upload_id_of(metadata: String) -> String
  parsed = JSON.parse(metadata)
  return "" if not parsed.ok?

  found = JSON.decode(parsed.unwrap!, Pending)
  return "" if not found.ok?

  found.unwrap!.upload_id
end

## The key of a blob in the bucket.
def object_key(store: Store, key: String) -> String = "#{store.prefix}#{key}"

## The URLs for an upload of `byte_size` bytes under `key`. Each one signs the `content-length` of the request that it
## takes, so a browser cannot send more or less than it said; a file past one part also starts the multipart upload,
## and the `upload_id` is what `finish` and `abort` need.
def plan(store: Store, key: String, byte_size: Int) -> Result[Plan]
  name = object_key(store, key)
  if byte_size <= PART_BYTES
    url = try S3.presign_put(store.client.config, name, presign(byte_size))
    return ok(Plan(url: url))
  end

  id = try S3.create_multipart(store.client, name)
  count = (byte_size + PART_BYTES - 1) / PART_BYTES
  parts: List[PartUrl] = []
  for number in 1..count
    length = PART_BYTES
    if number == count
      length = byte_size - PART_BYTES * (count - 1)
    end

    url = try S3.presign_part(store.client.config, name, id, number, presign(length))
    parts = parts.push(PartUrl(number: number, url: url))
  end

  ok(Plan(upload_id: id, part_bytes: PART_BYTES, parts: parts))
end

## Completes a multipart upload with the parts that S3 holds, so the browser tells no ETag. It is an `error` unless
## those are exactly the parts of a file of `byte_size` bytes cut as `plan` cut it.
def finish(store: Store, key: String, upload_id: String, byte_size: Int) -> Result[Void]
  name = object_key(store, key)
  held = try S3.list_parts(store.client, name, upload_id)
  count = (byte_size + PART_BYTES - 1) / PART_BYTES
  return error("the upload has #{held.length} parts, not #{count}") if held.length != count

  for part in held
    wanted = PART_BYTES
    if part.number == count
      wanted = byte_size - PART_BYTES * (count - 1)
    end

    if part.number < 1 or part.number > count or part.size != wanted
      return error("part #{part.number} has #{part.size} bytes, not #{wanted}")
    end
  end

  _ = try S3.complete_multipart(store.client, name, upload_id, held)
  ok()
end

## Stores the file at `path` under `key`, in parts when it is big (the server received it in the form).
def put_file(store: Store, key: String, path: String, content_type: String) -> Result[Void]
  _ = try S3.upload_file(store.client, object_key(store, key), path, S3.UploadOptions(content_type: content_type))
  ok()
end

## The size of the object, or an `error` when it is not there (an upload that did not finish).
def size_of(store: Store, key: String) -> Result[Int]
  info = try S3.head(store.client, object_key(store, key))
  ok(info.size)
end

## The first `count` bytes of the object, which tell its type.
def first_bytes(store: Store, key: String, count: Int) -> Result[Bytes]
  found = try S3.get_range(store.client, object_key(store, key), 0, count - 1)
  ok(found.body)
end

## The link of a download: a signed `GET` that makes S3 answer with `content_type` and, unless `inline`, as a download of
## `filename`.
def download_url(store: Store, key: String, filename: String, content_type: String, inline: Bool) -> Result[String]
  disposition = "attachment; filename=\"#{filename.replace("\"", "")}\""
  if inline
    disposition = "inline"
  end

  query = [
    S3.Param(name: "response-content-disposition", value: disposition),
    S3.Param(name: "response-content-type", value: content_type),
  ]

  S3.presign_get(store.client.config, object_key(store, key), S3.Presign(expires_s: DOWNLOAD_SECONDS, query: query))
end

## Deletes the object and, when `upload_id` is not empty, the parts of an upload that was not completed. A failure is
## logged: the row is gone or going, so nothing links the object, and the sweep of unattached uploads goes back to
## those that it can still name.
def remove(store: Store, key: String, upload_id: String) -> Void
  name = object_key(store, key)
  if not upload_id.empty?
    case S3.abort_multipart(store.client, name, upload_id)
      error(e) if e.kind != S3.NO_SUCH_UPLOAD -> IO.warn("campfire: cannot abort the upload of #{key}: #{e.message}")
      _ -> nil
    end
  end

  gone = S3.delete(store.client, name)
  if not gone.ok?
    IO.warn("campfire: cannot delete the object #{key}: #{gone.message}")
  end
end

private

def presign(length: Int) -> S3.Presign
  S3.Presign(expires_s: UPLOAD_SECONDS, headers: [S3.Param(name: "content-length", value: "#{length}")])
end
