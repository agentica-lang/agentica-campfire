"""A raw-socket WebSocket client for `cable.feature`: the independent peer of the cable server.

It shares no code with the server or with std/http. It speaks RFC 6455 by hand over `socket`, so a scenario can set the
Cookie, the Origin and the subprotocol (which the browser clients of other languages cannot) and keep many connections
open at once. A reader thread per connection answers pings with pongs, as a browser does, and queues what it reads.

Usage: cable_peer.py PORT. It reads one JSON command per line on stdin and answers one JSON line each:
  connect id path [headers] [protocols] -> {status, headers}     send id text -> {}
  recv id timeout_ms -> {text} | {closed: code} | {timeout: true}
  close id (a close frame) | drop id (no close frame) | ended id timeout_ms -> {ended: bool}
"""
import base64
import json
import os
import queue
import socket
import struct
import sys
import threading

PORT = int(sys.argv[1])
TEXT, CLOSE, PING, PONG = 1, 8, 9, 10
connections = {}


class Peer:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=30)
        self.buffer = b""
        self.texts = queue.Queue()
        self.finished = threading.Event()

    def read(self, count):
        while len(self.buffer) < count:
            more = self.sock.recv(65536)
            if not more:
                raise EOFError
            self.buffer += more
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def frame(self, opcode, payload=b""):
        key = os.urandom(4)
        head = bytes([128 | opcode])
        if len(payload) < 126:
            head += bytes([128 | len(payload)])
        elif len(payload) < 65536:
            head += bytes([128 | 126]) + struct.pack(">H", len(payload))
        else:
            head += bytes([128 | 127]) + struct.pack(">Q", len(payload))
        masked = bytes(byte ^ key[place % 4] for place, byte in enumerate(payload))
        self.sock.sendall(head + key + masked)

    def handshake(self, path, headers, protocols):
        lines = ["GET %s HTTP/1.1" % path, "Host: 127.0.0.1:%d" % PORT, "Upgrade: websocket", "Connection: Upgrade",
                 "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: " + base64.b64encode(os.urandom(16)).decode()]
        if protocols:
            lines.append("Sec-WebSocket-Protocol: " + protocols)
        lines += ["%s: %s" % item for item in headers.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        while b"\r\n\r\n" not in self.buffer:
            more = self.sock.recv(65536)
            if not more:
                raise EOFError
            self.buffer += more
        head, _, self.buffer = self.buffer.partition(b"\r\n\r\n")
        status, *fields = head.decode().split("\r\n")
        answer = {k.lower(): v for k, v in (field.split(": ", 1) for field in fields)}
        self.sock.settimeout(None)
        return int(status.split(" ")[1]), answer

    def reader(self):
        try:
            while True:
                first, second = self.read(2)
                size = second & 127
                if size == 126:
                    size = struct.unpack(">H", self.read(2))[0]
                elif size == 127:
                    size = struct.unpack(">Q", self.read(8))[0]
                opcode, payload = first & 15, self.read(size)
                if opcode == TEXT:
                    self.texts.put({"text": payload.decode()})
                elif opcode == PING:
                    self.frame(PONG, payload)
                elif opcode == CLOSE:
                    code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                    self.texts.put({"closed": code})
                    self.frame(CLOSE, payload[:2])
        except (EOFError, OSError):
            self.texts.put({"closed": 1006})
        finally:
            self.finished.set()


def run(command):
    peer = connections.get(command.get("id"))
    op = command["op"]
    if op == "connect":
        peer = Peer()
        status, headers = peer.handshake(command["path"], command.get("headers", {}), command.get("protocols", ""))
        connections[command["id"]] = peer
        if status == 101:
            threading.Thread(target=peer.reader, daemon=True).start()
        return {"status": status, "headers": headers}
    if op == "send":
        peer.frame(TEXT, command["text"].encode())
        return {}
    if op == "recv":
        try:
            return peer.texts.get(timeout=command["timeout_ms"] / 1000)
        except queue.Empty:
            return {"timeout": True}
    if op == "close":
        peer.frame(CLOSE, struct.pack(">H", 1000))
        return {}
    if op == "drop":
        peer.sock.shutdown(socket.SHUT_RDWR)
        peer.sock.close()
        return {}
    if op == "ended":
        return {"ended": peer.finished.wait(command["timeout_ms"] / 1000)}
    raise ValueError(op)


for line in sys.stdin:
    try:
        answer = run(json.loads(line))
    except Exception as error:
        answer = {"error": repr(error)}
    print(json.dumps(answer), flush=True)
