"""The webhook of a bot for the specs: an HTTP server on 127.0.0.1 and a free port.

It prints `listening PORT`, then one JSON line for each post it gets (the path, the content type and the body). It
answers each post (only those to WEBHOOK_PEER_SLOW_PATH, when it is set) after WEBHOOK_PEER_DELAY_MS milliseconds with WEBHOOK_PEER_REPLY as WEBHOOK_PEER_TYPE (an empty
reply is a 204).
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY_MS = int(os.environ.get("WEBHOOK_PEER_DELAY_MS", "0"))
REPLY = os.environ.get("WEBHOOK_PEER_REPLY", "")
TYPE = os.environ.get("WEBHOOK_PEER_TYPE", "text/plain")
SLOW_PATH = os.environ.get("WEBHOOK_PEER_SLOW_PATH", "")


class Webhook(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        seen = {"path": self.path, "content_type": self.headers.get("Content-Type", ""), "body": json.loads(body)}
        print(json.dumps(seen, sort_keys=True), flush=True)
        if not SLOW_PATH or self.path == SLOW_PATH:
            time.sleep(DELAY_MS / 1000)
        data = REPLY.encode("utf-8")
        self.send_response(200 if data else 204)
        if data:
            self.send_header("Content-Type", TYPE)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Webhook)
    server.daemon_threads = True
    print(f"listening {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)


if __name__ == "__main__":
    main()
