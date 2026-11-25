#!/usr/bin/env python3
"""A small S3 server on Python's standard library, the independent peer of the specs of the s3 package.

It checks the AWS Signature Version 4 of every request (the Authorization header or the X-Amz-* query of a presigned
URL) with its own code, and serves one bucket: PUT, GET (with Range), HEAD and DELETE of objects, and multipart uploads
(create, upload part, complete, abort, list parts). Errors are the XML of S3 (`NoSuchKey`, `AccessDenied`,
`SignatureDoesNotMatch`, ...). Objects live in files under a temporary folder that is removed on exit.

    s3_stub.py --bucket NAME --access-key ID --secret-key SECRET [--region R] [--session-token T] [--port N]

It prints `port N` on its first line, once it listens on 127.0.0.1, and serves until it is killed. A request that is
virtual-host style (the Host starts with `BUCKET.`) has the key as its path, a path-style one has `/BUCKET/KEY`.
`GET /__stub/requests` answers one line per request seen (`METHOD PATH?QUERY STATUS`), for a spec that wants to know
what the client sent.
"""

import argparse
import datetime
import hashlib
import hmac
import http.server
import os
import re
import shutil
import signal
import socketserver
import sys
import tempfile
import threading
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import parse_qsl, quote, unquote

MIN_PART = 5 * 1024 * 1024
CHUNK = 1 << 20
LOCK = threading.Lock()
OBJECTS = {}
UPLOADS = {}
SEEN = []
ARGS = None
ROOT = None


def sign_key(secret, date, region):
    key = ("AWS4" + secret).encode()
    for part in (date, region, "s3", "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    return key


def encode(text, keep_slash=False):
    return quote(text, safe="/-._~" if keep_slash else "-._~")


def canonical_query(pairs):
    return "&".join(f"{k}={v}" for k, v in sorted((encode(k), encode(v)) for k, v in pairs))


class S3Error(Exception):
    def __init__(self, status, code, message, extra=""):
        self.status, self.code, self.message, self.extra = status, code, message, extra


def xml_escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "s3stub"

    def log_message(self, *args):
        pass

    def handle_one(self):
        self.status_sent = 0
        raw_path, _, raw_query = self.path.partition("?")
        if raw_path == "/__stub/requests":
            with LOCK:
                body = "".join(line + "\n" for line in SEEN).encode()
            return self.reply(200, body, {"Content-Type": "text/plain"})
        try:
            if self.command == "OPTIONS":
                return self.reply(200, b"", {"Access-Control-Allow-Methods": "GET, PUT, POST, DELETE, HEAD",
                                            "Access-Control-Allow-Headers": self.headers.get("Access-Control-Request-Headers", "*"),
                                            "Access-Control-Max-Age": "600"})
            pairs = parse_qsl(raw_query, keep_blank_values=True)
            self.verify(raw_path, pairs)
            key = self.key_of(raw_path)
            self.route(key, dict(pairs))
        except S3Error as e:
            self.error(e)
        finally:
            with LOCK:
                SEEN.append(f"{self.command} {self.path} {self.status_sent}")

    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = do_OPTIONS = handle_one

    def reply(self, status, body=b"", headers=None, length=None):
        self.status_sent = status
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "ETag, x-amz-request-id")
        self.send_header("x-amz-request-id", "STUB0001")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if self.command != "HEAD" or length is None:
            self.send_header("Content-Length", str(len(body) if length is None else length))
        else:
            self.send_header("Content-Length", str(length))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def error(self, e):
        body = ('<?xml version="1.0" encoding="UTF-8"?><Error><Code>%s</Code><Message>%s</Message>%s'
                '<RequestId>STUB0001</RequestId></Error>' % (e.code, xml_escape(e.message), e.extra)).encode()
        # the body of an upload that was refused may be unread: close, so the next request starts clean
        unread = int(self.headers.get("Content-Length", "0") or 0) - self.read_so_far
        if unread > 0:
            self.close_connection = True
        self.reply(e.status, body, {"Content-Type": "application/xml"}, None if self.command != "HEAD" else 0)

    read_so_far = 0

    # ---- SigV4 ----

    def verify(self, raw_path, pairs):
        self.read_so_far = 0
        query = dict(pairs)
        auth = self.headers.get("Authorization", "")
        if "X-Amz-Signature" in query:
            return self.verify_presigned(raw_path, pairs, query)
        if not auth:
            raise S3Error(403, "AccessDenied", "Access Denied")
        m = re.fullmatch(r"AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([0-9a-f]+)", auth)
        if not m:
            raise S3Error(400, "AuthorizationHeaderMalformed", "bad Authorization header")
        credential, signed, signature = m.groups()
        access, date, region, service, term = credential.split("/")
        amz_date = self.headers.get("x-amz-date", "")
        payload = self.headers.get("x-amz-content-sha256", "")
        if not payload:
            raise S3Error(400, "InvalidRequest", "missing x-amz-content-sha256")
        self.check_scope(access, date, region, service, term, amz_date)
        names = signed.split(";")
        self.require_signed(names, sorted(k.lower() for k in self.headers.keys() if k.lower().startswith("x-amz-")))
        headers = "".join(f"{n}:{' '.join(self.headers.get(n, '').split())}\n" for n in names)
        canonical = "\n".join([self.command, encode(unquote(raw_path), True), canonical_query(pairs), headers, signed, payload])
        self.check_signature(canonical, amz_date, date, region, signature)
        self.payload_hash = payload

    def verify_presigned(self, raw_path, pairs, query):
        if query.get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256":
            raise S3Error(400, "AuthorizationQueryParametersError", "bad X-Amz-Algorithm")
        access, date, region, service, term = query["X-Amz-Credential"].split("/")
        amz_date = query["X-Amz-Date"]
        self.check_scope(access, date, region, service, term, amz_date)
        if ARGS.session_token and query.get("X-Amz-Security-Token") != ARGS.session_token:
            raise S3Error(403, "InvalidToken", "The provided token is malformed or otherwise invalid.")
        issued = datetime.datetime.strptime(amz_date, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc)
        lifetime = int(query["X-Amz-Expires"])
        if not 1 <= lifetime <= 604800:
            raise S3Error(400, "AuthorizationQueryParametersError", "X-Amz-Expires must be between 1 and 604800")
        if datetime.datetime.now(datetime.timezone.utc) > issued + datetime.timedelta(seconds=lifetime):
            raise S3Error(403, "AccessDenied", "Request has expired")
        signed = query["X-Amz-SignedHeaders"]
        self.require_signed(signed.split(";"), [])
        headers = "".join(f"{n}:{' '.join(self.headers.get(n, '').split())}\n" for n in signed.split(";"))
        rest = [p for p in pairs if p[0] != "X-Amz-Signature"]
        canonical = "\n".join([self.command, encode(unquote(raw_path), True), canonical_query(rest), headers, signed,
                               "UNSIGNED-PAYLOAD"])
        self.check_signature(canonical, amz_date, date, region, query["X-Amz-Signature"])
        self.payload_hash = "UNSIGNED-PAYLOAD"

    def require_signed(self, names, amz_headers):
        """S3 refuses a request that leaves `host` or an `x-amz-*` header out of SignedHeaders."""
        missing = [n for n in ["host"] + amz_headers if n not in names]
        if missing:
            raise S3Error(403, "AccessDenied", "SignedHeaders lacks " + ",".join(missing))

    def check_scope(self, access, date, region, service, term, amz_date):
        if access != ARGS.access_key:
            raise S3Error(403, "InvalidAccessKeyId", "The AWS Access Key Id you provided does not exist in our records.")
        if (region, service, term) != (ARGS.region, "s3", "aws4_request") or not amz_date.startswith(date):
            raise S3Error(403, "AuthorizationHeaderMalformed", "the credential scope is wrong")
        if ARGS.session_token and self.headers.get("x-amz-security-token", "") != ARGS.session_token \
                and "X-Amz-Signature" not in dict(parse_qsl(self.path.partition("?")[2], keep_blank_values=True)):
            raise S3Error(403, "InvalidToken", "The provided token is malformed or otherwise invalid.")

    def check_signature(self, canonical, amz_date, date, region, signature):
        scope = f"{date}/{region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        expected = hmac.new(sign_key(ARGS.secret_key, date, region), to_sign.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            raise S3Error(403, "SignatureDoesNotMatch",
                          "The request signature we calculated does not match the signature you provided.",
                          "<CanonicalRequest>%s</CanonicalRequest>" % xml_escape(canonical))

    # ---- routes ----

    def key_of(self, raw_path):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        path = unquote(raw_path)
        if host.startswith(ARGS.bucket + "."):
            return path.lstrip("/")
        prefix = "/" + ARGS.bucket
        if path == prefix or path.startswith(prefix + "/"):
            return path[len(prefix):].lstrip("/")
        raise S3Error(404, "NoSuchBucket", "The specified bucket does not exist")

    def body_to_file(self, path):
        length = int(self.headers.get("Content-Length", "0") or 0)
        md5, sha = hashlib.md5(), hashlib.sha256()
        with open(path, "wb") as out:
            while self.read_so_far < length:
                chunk = self.rfile.read(min(CHUNK, length - self.read_so_far))
                if not chunk:
                    break
                self.read_so_far += len(chunk)
                md5.update(chunk)
                sha.update(chunk)
                out.write(chunk)
        if self.read_so_far != length:
            raise S3Error(400, "IncompleteBody", "You did not provide the number of bytes specified")
        if self.payload_hash not in ("UNSIGNED-PAYLOAD",) and sha.hexdigest() != self.payload_hash:
            raise S3Error(400, "XAmzContentSHA256Mismatch", "The provided 'x-amz-content-sha256' header does not match what was computed.")
        return md5.hexdigest(), length

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        data = self.rfile.read(length)
        self.read_so_far += len(data)
        if self.payload_hash != "UNSIGNED-PAYLOAD" and hashlib.sha256(data).hexdigest() != self.payload_hash:
            raise S3Error(400, "XAmzContentSHA256Mismatch", "The provided 'x-amz-content-sha256' header does not match what was computed.")
        return data

    def route(self, key, query):
        if not key:
            raise S3Error(501, "NotImplemented", "bucket operations are not served by the stub")
        method = self.command
        if method == "POST" and "uploads" in query:
            return self.create_upload(key)
        if method == "POST" and "uploadId" in query:
            return self.complete_upload(key, query["uploadId"])
        if method == "PUT" and "uploadId" in query:
            return self.put_part(key, query)
        if method == "DELETE" and "uploadId" in query:
            return self.abort_upload(key, query["uploadId"])
        if method == "GET" and "uploadId" in query:
            return self.list_parts(key, query)
        if method == "PUT":
            return self.put_object(key)
        if method in ("GET", "HEAD"):
            return self.get_object(key, query)
        if method == "DELETE":
            with LOCK:
                OBJECTS.pop(key, None)
            return self.reply(204)
        raise S3Error(405, "MethodNotAllowed", "The specified method is not allowed against this resource.")

    def put_object(self, key):
        path = os.path.join(ROOT, uuid.uuid4().hex)
        etag, size = self.body_to_file(path)
        self.store(key, path, f'"{etag}"', size)
        self.reply(200, b"", {"ETag": f'"{etag}"'})

    def store(self, key, path, etag, size):
        meta = {"path": path, "etag": etag, "size": size, "type": self.headers.get("Content-Type", "binary/octet-stream"),
                "modified": datetime.datetime.now(datetime.timezone.utc)}
        with LOCK:
            old = OBJECTS.get(key)
            OBJECTS[key] = meta
        if old:
            os.unlink(old["path"])

    def get_object(self, key, query):
        with LOCK:
            meta = OBJECTS.get(key)
        if not meta:
            raise S3Error(404, "NoSuchKey", "The specified key does not exist.", f"<Key>{xml_escape(key)}</Key>")
        size, start, end, status = meta["size"], 0, meta["size"] - 1, 200
        headers = {"ETag": meta["etag"], "Accept-Ranges": "bytes",
                   "Content-Type": query.get("response-content-type", meta["type"]),
                   "Last-Modified": meta["modified"].strftime("%a, %d %b %Y %H:%M:%S GMT")}
        if "response-content-disposition" in query:
            headers["Content-Disposition"] = query["response-content-disposition"]
        rng = self.headers.get("Range")
        if rng:
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng)
            if not m or (m.group(1) == "" and m.group(2) == ""):
                raise S3Error(400, "InvalidArgument", "bad Range")
            if m.group(1) == "":
                start = max(size - int(m.group(2)), 0)
            else:
                start = int(m.group(1))
                if m.group(2) != "":
                    end = min(int(m.group(2)), size - 1)
            if start >= size:
                raise S3Error(416, "InvalidRange", "The requested range is not satisfiable")
            status = 206
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        count = end - start + 1
        self.status_sent = status
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "ETag, x-amz-request-id")
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(count))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(meta["path"], "rb") as f:
            f.seek(start)
            while count > 0:
                chunk = f.read(min(CHUNK, count))
                if not chunk:
                    break
                self.wfile.write(chunk)
                count -= len(chunk)

    # ---- multipart ----

    def create_upload(self, key):
        upload = uuid.uuid4().hex
        folder = os.path.join(ROOT, upload)
        os.mkdir(folder)
        with LOCK:
            UPLOADS[upload] = {"key": key, "dir": folder, "parts": {}, "type": self.headers.get("Content-Type", "binary/octet-stream")}
        xml = ('<?xml version="1.0" encoding="UTF-8"?><InitiateMultipartUploadResult><Bucket>%s</Bucket><Key>%s</Key>'
               '<UploadId>%s</UploadId></InitiateMultipartUploadResult>' % (ARGS.bucket, xml_escape(key), upload))
        self.reply(200, xml.encode(), {"Content-Type": "application/xml"})

    def upload_of(self, key, upload):
        with LOCK:
            found = UPLOADS.get(upload)
        if not found or found["key"] != key:
            raise S3Error(404, "NoSuchUpload", "The specified upload does not exist.", f"<UploadId>{upload}</UploadId>")
        return found

    def put_part(self, key, query):
        found = self.upload_of(key, query["uploadId"])
        number = int(query.get("partNumber", "0"))
        if not 1 <= number <= 10000:
            raise S3Error(400, "InvalidArgument", "Part number must be an integer between 1 and 10000, inclusive")
        if key.startswith("fail-part-2/") and number == 2:
            raise S3Error(500, "InternalError", "We encountered an internal error. Please try again.")
        path = os.path.join(found["dir"], str(number))
        etag, size = self.body_to_file(path)
        with LOCK:
            found["parts"][number] = (f'"{etag}"', size, datetime.datetime.now(datetime.timezone.utc))
        self.reply(200, b"", {"ETag": f'"{etag}"'})

    def complete_upload(self, key, upload):
        found = self.upload_of(key, upload)
        try:
            root = ET.fromstring(self.read_body())
        except ET.ParseError:
            raise S3Error(400, "MalformedXML", "The XML you provided was not well-formed")
        wanted = [(int(p.findtext("PartNumber")), p.findtext("ETag")) for p in root.iter("Part")]
        if not wanted:
            raise S3Error(400, "MalformedXML", "no parts")
        if [n for n, _ in wanted] != sorted(n for n, _ in wanted):
            raise S3Error(400, "InvalidPartOrder", "The list of parts was not in ascending order.")
        digests = b""
        for index, (number, etag) in enumerate(wanted):
            have = found["parts"].get(number)
            if not have or have[0].strip('"') != (etag or "").strip('"'):
                raise S3Error(400, "InvalidPart", "One or more of the specified parts could not be found.")
            if have[1] < MIN_PART and index < len(wanted) - 1:
                raise S3Error(400, "EntityTooSmall", "Your proposed upload is smaller than the minimum allowed size")
            digests += bytes.fromhex(have[0].strip('"'))
        path = os.path.join(ROOT, uuid.uuid4().hex)
        size = 0
        with open(path, "wb") as out:
            for number, _ in wanted:
                with open(os.path.join(found["dir"], str(number)), "rb") as part:
                    shutil.copyfileobj(part, out, CHUNK)
                size += found["parts"][number][1]
        etag = f'"{hashlib.md5(digests).hexdigest()}-{len(wanted)}"'
        meta = {"path": path, "etag": etag, "size": size, "type": found["type"],
                "modified": datetime.datetime.now(datetime.timezone.utc)}
        with LOCK:
            old = OBJECTS.get(key)
            OBJECTS[key] = meta
            UPLOADS.pop(upload, None)
        if old:
            os.unlink(old["path"])
        shutil.rmtree(found["dir"], ignore_errors=True)
        xml = ('<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUploadResult><Location>http://stub/%s/%s</Location>'
               '<Bucket>%s</Bucket><Key>%s</Key><ETag>%s</ETag></CompleteMultipartUploadResult>'
               % (ARGS.bucket, xml_escape(key), ARGS.bucket, xml_escape(key), xml_escape(etag)))
        self.reply(200, xml.encode(), {"Content-Type": "application/xml"})

    def abort_upload(self, key, upload):
        found = self.upload_of(key, upload)
        with LOCK:
            UPLOADS.pop(upload, None)
        shutil.rmtree(found["dir"], ignore_errors=True)
        self.reply(204)

    def list_parts(self, key, query):
        found = self.upload_of(key, query["uploadId"])
        marker = int(query.get("part-number-marker", "0"))
        limit = min(int(query.get("max-parts", "1000")), 1000)
        numbers = sorted(n for n in found["parts"] if n > marker)
        page, truncated = numbers[:limit], len(numbers) > limit
        parts = "".join(
            "<Part><PartNumber>%d</PartNumber><LastModified>%s</LastModified><ETag>%s</ETag><Size>%d</Size></Part>"
            % (n, found["parts"][n][2].strftime("%Y-%m-%dT%H:%M:%S.000Z"), xml_escape(found["parts"][n][0]),
               found["parts"][n][1]) for n in page)
        xml = ('<?xml version="1.0" encoding="UTF-8"?><ListPartsResult><Bucket>%s</Bucket><Key>%s</Key><UploadId>%s</UploadId>'
               '<PartNumberMarker>%d</PartNumberMarker><NextPartNumberMarker>%d</NextPartNumberMarker><MaxParts>%d</MaxParts>'
               '<IsTruncated>%s</IsTruncated>%s</ListPartsResult>'
               % (ARGS.bucket, xml_escape(key), query["uploadId"], marker, page[-1] if page else marker, limit,
                  "true" if truncated else "false", parts))
        self.reply(200, xml.encode(), {"Content-Type": "application/xml"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 64


def main():
    global ARGS, ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--access-key", required=True)
    parser.add_argument("--secret-key", required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--session-token", default="")
    parser.add_argument("--port", type=int, default=0)
    ARGS = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    ROOT = tempfile.mkdtemp(prefix="s3stub-")
    server = Server(("127.0.0.1", ARGS.port), Handler)
    print(f"port {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        shutil.rmtree(ROOT, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
