#!/usr/bin/env python3
"""Local kokoro.io REST / ActionCable fixture. Python 3 standard library only.

Start: python3 scripts/mock-server.py
Tree scenario: python3 scripts/mock-server.py --channel-tree
Sign in: http://127.0.0.1:8765 with the public test token test-token.
Inspect: GET /test/state with X-Access-Token: test-token.
Publish: POST /test/publish with {"channel_id":"CHAN00002","content":"Hello"}.
The test endpoints use the same header. This is a development fixture, not a server.
"""

import argparse
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import struct
import threading
import time
from urllib.parse import parse_qs, urlsplit
import uuid

TOKEN = "test-token"
IDENTIFIER = '{"channel":"ChatChannel"}'
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def timestamp(value=None):
    return (value or datetime.now(timezone.utc)).isoformat(timespec="seconds")


def profile(identifier, screen_name, display_name):
    return {"id": identifier, "type": "User", "screen_name": screen_name,
            "display_name": display_name, "avatar": None, "avatars": [],
            "archived": False, "invited_channels_count": 0}


class Fixture:
    def __init__(self, channel_tree=False):
        self.lock = threading.RLock()
        self.clients = set()
        self.records = []
        self.next_id = 1
        self.me = profile("SELF00001", "you", "あなた")
        self.other = profile("OTHER0001", "hana", "Hana Tanaka")
        self.channels = {}
        self.memberships = {}
        self.messages = {}
        channels = [
            ("general", "public_channel", "みんなで気軽に話す場所。REST とリアルタイム通信を確認できます。"),
            ("team-private", "private_channel", "非公開チャンネル。別チャンネルからの新着と通知のテスト用。"),
            ("Hana Tanaka", "direct_message", "ダイレクトメッセージ"),
        ]
        if channel_tree:
            channels.extend([
                ("OS/Linux", "public_channel", "同じ名前のチャンネルとグループを確認できます。"),
                ("OS/Linux/Ubuntu", "public_channel", "3 階層のチャンネル。"),
                ("OS/Windows", "public_channel", "同じグループ内のチャンネル。"),
                ("OS/macOS", "public_channel", "同じグループ内のチャンネル。"),
                ("times/mohemohe", "public_channel", "個人用チャンネル。"),
                ("times/supermomonga", "public_channel", "個人用チャンネル。"),
                *[(f"/dev/{name}", "public_channel", "先頭の空の階層を確認できます。")
                  for name in ("null", "random", "stderr", "stdin", "stdout")],
                ("OS/Linux", "private_channel", "公開チャンネルと同名の非公開チャンネル。"),
                ("OS/Windows", "private_channel", "非公開グループ内のチャンネル。"),
                ("Hana / Design", "direct_message", "スラッシュを含むダイレクトメッセージ名。"),
            ])
        for index, (name, kind, description) in enumerate(channels, 1):
            channel_id = f"CHAN{index:05d}"
            self.channels[channel_id] = {
                "id": channel_id, "channel_name": name, "kind": kind,
                "archived": False, "description": description,
                "latest_message_id": None, "latest_message_published_at": None, "messages_count": 0,
            }
            self.memberships[channel_id] = {
                "id": f"MEMB{index:05d}", "authority": "member", "disable_notification": False,
                "notification_policy": "all_messages", "read_state_tracking_policy": "keep_latest",
                "latest_read_message_id": 0, "unread_count": 0, "visible": True,
                "muted": False, "profile": self.me,
            }
            self.messages[channel_id] = []
            count = 125 if index == 1 else 4
            start = datetime.now(timezone.utc) - timedelta(minutes=count + 10)
            for number in range(1, count + 1):
                author = self.me if number % 4 == 0 else self.other
                content = f"{name} の会話 {number}。過去のメッセージもそのまま読めます。"
                if number == count:
                    content = "ローカルサーバーに接続しました。メッセージを送信してみてください。"
                self.add_message(channel_id, content, author, published_at=timestamp(start + timedelta(minutes=number)))
            self.memberships[channel_id]["latest_read_message_id"] = self.channels[channel_id]["latest_message_id"] - 2
            self.memberships[channel_id]["unread_count"] = 2

    def record(self, kind, **values):
        with self.lock:
            self.records.append({"type": kind, "at": timestamp(), **values})
            self.records = self.records[-300:]
        print(json.dumps({"type": kind, **values}, ensure_ascii=False), flush=True)

    def channel(self, channel_id, with_membership=False):
        result = copy.deepcopy(self.channels[channel_id])
        if with_membership:
            result["membership"] = copy.deepcopy(self.memberships[channel_id])
        return result

    def membership(self, channel_id):
        return {**copy.deepcopy(self.memberships[channel_id]), "channel": self.channel(channel_id)}

    def add_message(self, channel_id, content, author, key=None, published_at=None):
        with self.lock:
            if key:
                existing = next((m for m in self.messages[channel_id] if m["idempotent_key"] == key), None)
                if existing:
                    return copy.deepcopy(existing), False
            message_id = self.next_id
            self.next_id += 1
            published_at = published_at or timestamp()
            channel = self.channels[channel_id]
            channel["latest_message_id"] = message_id
            channel["latest_message_published_at"] = published_at
            channel["messages_count"] += 1
            message = {
                "id": message_id, "idempotent_key": key or str(uuid.uuid4()),
                "display_name": author["display_name"], "avatar": None, "avatars": [],
                "expand_embed_contents": True, "status": "active", "content": html.escape(content),
                "html_content": html.escape(content), "plaintext_content": content, "raw_content": content,
                "embedded_urls": [], "embed_contents": [], "published_at": published_at,
                "nsfw": False, "channel": self.channel(channel_id), "profile": copy.deepcopy(author),
            }
            self.messages[channel_id].append(message)
            if author["id"] != self.me["id"]:
                self.memberships[channel_id]["unread_count"] += 1
            return copy.deepcopy(message), True

    def broadcast(self, event, payload, channel_id=None):
        with self.lock:
            clients = list(self.clients)
        sent = 0
        for client in clients:
            if client.subscribed and (channel_id is None or channel_id in client.channel_ids):
                try:
                    client.send_json({"identifier": IDENTIFIER, "message": {"event": event, "data": payload}})
                    sent += 1
                except (OSError, ValueError):
                    client.closed.set()
        self.record("broadcast", event=event, channel_id=channel_id, clients=sent)


FIXTURE = None


class WebSocket:
    def __init__(self, handler):
        self.handler = handler
        self.closed = threading.Event()
        self.write_lock = threading.Lock()
        self.channel_ids = set()
        self.subscribed = False

    def send(self, payload, opcode=1):
        size = len(payload)
        if size < 126:
            header = bytes([0x80 | opcode, size])
        elif size <= 65535:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", size)
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", size)
        with self.write_lock:
            self.handler.wfile.write(header + payload)
            self.handler.wfile.flush()

    def send_json(self, value):
        self.send(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def read_exact(self, count):
        data = self.handler.rfile.read(count)
        if len(data) != count:
            raise EOFError()
        return data

    def read_frame(self):
        first, second = self.read_exact(2)
        opcode, masked, size = first & 0x0F, second & 0x80, second & 0x7F
        if not first & 0x80:
            raise ValueError("Fragmented frames are not needed by this fixture")
        if size == 126:
            size = struct.unpack("!H", self.read_exact(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.read_exact(8))[0]
        if size > 1024 * 1024:
            raise ValueError("Frame too large")
        mask = self.read_exact(4) if masked else None
        payload = self.read_exact(size)
        if mask:
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        return opcode, payload

    def pings(self):
        while not self.closed.wait(3):
            try:
                self.send_json({"type": "ping", "message": int(time.time())})
            except OSError:
                self.closed.set()

    def run(self):
        with FIXTURE.lock:
            FIXTURE.clients.add(self)
        FIXTURE.record("websocket_open", origin=self.handler.headers.get("Origin"))
        self.send_json({"type": "welcome"})
        threading.Thread(target=self.pings, daemon=True).start()
        try:
            while not self.closed.is_set():
                opcode, payload = self.read_frame()
                if opcode == 8:
                    self.send(payload, opcode=8)
                    break
                if opcode == 9:
                    self.send(payload, opcode=10)
                    continue
                if opcode != 1:
                    continue
                frame = json.loads(payload)
                FIXTURE.record("websocket_frame", frame=frame)
                if frame.get("identifier") != IDENTIFIER:
                    continue
                if frame.get("command") == "subscribe":
                    self.send_json({"type": "confirm_subscription", "identifier": IDENTIFIER})
                elif frame.get("command") == "unsubscribe":
                    self.subscribed = False
                    self.channel_ids.clear()
                elif frame.get("command") == "message":
                    action = json.loads(frame.get("data", "{}"))
                    if action.get("action") == "unsubscribe":
                        self.subscribed = False
                        self.channel_ids.clear()
                    elif action.get("action") == "subscribe":
                        self.subscribed = True
                        self.channel_ids.update(c for c in action.get("channels", []) if c in FIXTURE.channels)
                        for channel_id in sorted(self.channel_ids):
                            with FIXTURE.lock:
                                channel = FIXTURE.channel(channel_id, with_membership=True)
                            self.send_json({"identifier": IDENTIFIER, "message": {"event": "subscribed", "data": channel}})
        except (EOFError, OSError, ValueError, json.JSONDecodeError):
            pass
        finally:
            self.closed.set()
            with FIXTURE.lock:
                FIXTURE.clients.discard(self)
            FIXTURE.record("websocket_closed")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # Structured request records below deliberately exclude authentication headers.

    def json_response(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1024 * 1024:
            raise ValueError("Body too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def authorized(self):
        if self.headers.get("X-Access-Token") == TOKEN:
            return True
        self.json_response(401, {"message": "Invalid access token"})
        return False

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        FIXTURE.record("request", method="GET", path=path)
        if path == "/health":
            self.json_response(200, {"status": "ok", "fixture": True})
            return
        if not self.authorized():
            return
        if path == "/cable":
            key = self.headers.get("Sec-WebSocket-Key")
            if not key or self.headers.get("Upgrade", "").lower() != "websocket":
                self.json_response(400, {"message": "WebSocket upgrade required"})
                return
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode())
            if "actioncable-v1-json" in self.headers.get("Sec-WebSocket-Protocol", ""):
                self.send_header("Sec-WebSocket-Protocol", "actioncable-v1-json")
            self.end_headers()
            self.wfile.flush()
            WebSocket(self).run()
            self.close_connection = True
            return
        with FIXTURE.lock:
            if path == "/api/v1/profiles/me":
                value = FIXTURE.me
            elif path == "/api/v1/memberships":
                value = [FIXTURE.membership(c) for c in FIXTURE.channels]
            elif path == "/api/v1/channels":
                value = [FIXTURE.channel(c, True) for c in FIXTURE.channels if FIXTURE.channels[c]["kind"] == "public_channel"]
            elif path == "/test/state":
                value = {"records": copy.deepcopy(FIXTURE.records), "connections": len(FIXTURE.clients),
                         "subscriptions": [sorted(c.channel_ids) for c in FIXTURE.clients],
                         "memberships": [FIXTURE.membership(c) for c in FIXTURE.channels]}
            else:
                parts = path.strip("/").split("/")
                if len(parts) != 5 or parts[:3] != ["api", "v1", "channels"] or parts[4] != "messages" or parts[3] not in FIXTURE.channels:
                    self.json_response(404, {"message": "Not found"})
                    return
                query = parse_qs(parsed.query)
                try:
                    limit = min(1000, max(1, int(query.get("limit", [50])[0])))
                    before = int(query.get("before_id", [2**63])[0])
                    after = int(query.get("after_id", [0])[0])
                except ValueError:
                    self.json_response(400, {"message": "Invalid cursor"})
                    return
                value = [copy.deepcopy(m) for m in reversed(FIXTURE.messages[parts[3]]) if after < m["id"] < before][:limit]
            self.json_response(200, value)

    def do_POST(self):
        path = urlsplit(self.path).path
        FIXTURE.record("request", method="POST", path=path)
        if not self.authorized():
            return
        try:
            body = self.body()
        except (ValueError, json.JSONDecodeError):
            self.json_response(400, {"message": "Invalid JSON"})
            return
        if path == "/test/disconnect":
            with FIXTURE.lock:
                clients = list(FIXTURE.clients)
            for client in clients:
                client.send_json({"type": "disconnect", "reason": "restart", "reconnect": True})
                client.closed.set()
                client.handler.connection.shutdown(socket.SHUT_RDWR)
            self.json_response(200, {"disconnected": len(clients)})
            return
        if path == "/test/publish":
            channel_id = body.get("channel_id", "CHAN00002")
            content = body.get("content", "<@SELF00001|you> 新しいメッセージが届きました。")
            author, key = FIXTURE.other, None
        else:
            parts = path.strip("/").split("/")
            if len(parts) != 5 or parts[:3] != ["api", "v1", "channels"] or parts[4] != "messages":
                self.json_response(404, {"message": "Not found"})
                return
            channel_id, content, author, key = parts[3], body.get("message", ""), FIXTURE.me, body.get("idempotent_key")
        if channel_id not in FIXTURE.channels:
            self.json_response(404, {"message": "Channel not found"})
            return
        if not isinstance(content, str) or not content.strip() or len(content) > 4000:
            self.json_response(400, {"message": "Message must contain 1 to 4000 characters"})
            return
        message, created = FIXTURE.add_message(channel_id, content, author, key)
        if created:
            FIXTURE.broadcast("message_created", message, channel_id)
        self.json_response(201 if created else 200, message)

    def do_PUT(self):
        path = urlsplit(self.path).path
        FIXTURE.record("request", method="PUT", path=path)
        if not self.authorized():
            return
        parts = path.strip("/").split("/")
        if len(parts) != 4 or parts[:3] != ["api", "v1", "memberships"]:
            self.json_response(404, {"message": "Not found"})
            return
        try:
            body = self.body()
            with FIXTURE.lock:
                channel_id = next((c for c, m in FIXTURE.memberships.items() if m["id"] == parts[3]), None)
                if not channel_id:
                    self.json_response(404, {"message": "Membership not found"})
                    return
                membership = FIXTURE.memberships[channel_id]
                if "latest_read_message_id" in body:
                    cursor = int(body["latest_read_message_id"])
                    if cursor < membership["latest_read_message_id"] or not any(m["id"] == cursor for m in FIXTURE.messages[channel_id]):
                        self.json_response(400, {"message": "Invalid read cursor"})
                        return
                    membership["latest_read_message_id"] = cursor
                    # Matches current Rails REST behavior: unread_count remains unchanged.
                for key in ("notification_policy", "read_state_tracking_policy", "visible", "muted"):
                    if key in body:
                        membership[key] = body[key]
                self.json_response(200, FIXTURE.membership(channel_id))
        except (ValueError, json.JSONDecodeError):
            self.json_response(400, {"message": "Invalid JSON"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--channel-tree", action="store_true", help="Include hierarchical channel names")
    args = parser.parse_args()
    FIXTURE = Fixture(channel_tree=args.channel_tree)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    print(f"kokoro.io fixture: http://127.0.0.1:{args.port}  public test token: {TOKEN}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
