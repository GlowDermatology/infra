#!/usr/bin/env python3
"""Behaviour probe of caddy/Caddyfile: runs the real file in a real Caddy in front of two stub upstreams.

Usage: python3 caddy/edge_probe.py --caddy /path/to/caddy        (exit 0 = every check passed)

The Caddyfile runs as committed except for what a local run needs: plain HTTP on a free port (auto_https off,
no admin endpoint) and test host names (site.test, www.site.test, ops.test). API_UPSTREAM and FRONTEND_UPSTREAM
point at two different stubs, so every check knows whether Django or Next received a request. The ops console's
allow-list is 127.0.0.1 only; a request from 127.0.0.2 plays a browser outside it.

A third stub plays the object storage (SeaweedFS). The media checks run twice: with MEDIA_BACKEND=disk in the main
Caddy, then in a second Caddy with MEDIA_BACKEND=object-storage, where /media/* must be fetched from
/glowderma-media/media/... on that stub and nowhere else (GET and HEAD only, no listing, no traversal, no query
string, no credential forwarded, no Server or X-Amz-* header back).

Checks (same origin): /api/v1/* reaches Django and nothing else does; Next keeps its own /api/shop/* and
/api/revalidate; the staff-only Django paths answer 404 at the edge; /media/ is served from disk; body limits;
X-Forwarded-For is overwritten; no Server/Via header and HSTS everywhere; www redirects; the ops console gate;
a trickling client never reaches Django; server timeouts; and no secret or personal value from a query string,
a Referer or a token header appears in the access or error log, including the error line of a 502.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Iterator
from contextlib import closing, contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

CADDYFILE = Path(__file__).resolve().with_name("Caddyfile")
HOSTS = {"SITE_DOMAIN": "site.test", "OPS_DOMAIN": "ops.test"}
OPS_ALLOWED = "127.0.0.1/32"
OUTSIDE_ADDRESS = "127.0.0.2"  # a loopback source address outside OPS_ALLOWED
# Values that must never appear in a log line (each is sent once, in a query string or a header).
SECRETS = {
    "bts_token": "probe-bts-token-0123456789abcdef",
    "bts_header": "probe-bts-header-0123456789abcdef",
    "slow_token": "probe-slow-token-0123456789abcdef",
    "down_token": "probe-down-token-0123456789abcdef",
    "down_header": "probe-down-header-0123456789abcdef",
    "internal": "probe-internal-secret-0123456789abcdef",
    "phone": "998901234567",
    "referer_phone": "998907654321",
    "oauth_code": "probe-oauth-code-0123456789",
    "oauth_state": "probe-oauth-state-0123456789",
    "down_phone": "998909999999",
    "ops_phone": "998905555555",
}
MIB = 1024 * 1024
BUCKET = "glowderma-media"
STORED_PATH = f"/{BUCKET}/media/products/1/a.webp"  # the one object the storage stub holds
STORED_BODY = b"RIFF-webp-bytes"


@dataclass
class Seen:
    method: str
    path: str
    headers: dict[str, str]
    body_length: int


@dataclass
class Upstream:
    requests: list[Seen] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)
    down: bool = False  # True: drop every connection without an answer (the upstream is restarting)
    objects: dict[str, bytes] | None = None  # set: an object storage stub (path -> body), 404 for the rest
    port: int = 0
    errors: dict[str, int] = field(default_factory=dict)  # object storage stub: path -> error status

    def paths(self) -> list[str]:
        with self.lock:
            return [seen.path for seen in self.requests]


def free_port() -> int:
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("127.0.0.1", 0))
        port: int = sock.getsockname()[1]
        return port


def stub_server(upstream: Upstream) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def answer(self) -> None:
            if upstream.down:
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            # Recorded on arrival, before the body is read: a request forwarded while its body is still
            # trickling in shows up here at once.
            seen = Seen(self.command, self.path, dict(self.headers.items()), -1)
            with upstream.lock:
                upstream.requests.append(seen)
            length = int(self.headers.get("Content-Length") or 0)
            seen.body_length = len(self.rfile.read(length)) if length else 0
            if upstream.objects is not None:
                self.object_answer()
                return
            payload = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Server", "stub")
            # Django's own value: the ops host must replace it with DENY (one header, not two).
            self.send_header("X-Frame-Options", "SAMEORIGIN")
            self.end_headers()
            self.wfile.write(payload)

        def object_answer(self) -> None:
            """SeaweedFS: 200 with S3 headers for a stored object (the request path without its query), else 404."""
            key = self.path.split("?", 1)[0]
            payload = (upstream.objects or {}).get(key)
            body = payload if payload is not None else b"<Error><Code>NoSuchKey</Code></Error>"
            self.send_response(upstream.errors.get(key, 200 if payload is not None else 404))
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "image/webp" if payload is not None else "application/xml")
            self.send_header("Server", "SeaweedFS S3")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Amz-Request-Id", "probe-request-id")
            self.send_header("X-Amz-Id-2", "probe-id-2")
            self.send_header("X-Amz-Meta-Secret", "probe-meta")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = answer

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - BaseHTTPRequestHandler API
            return

    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, request: object, client_address: object) -> None:
            return  # the edge cut a too-large body short (413): nothing to report

    server = Server(("127.0.0.1", free_port()), Handler)
    upstream.port = int(server.server_address[1])
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def probe_caddyfile(port: int) -> str:
    """The committed Caddyfile, served over plain HTTP on ``port`` with test host names."""
    text = CADDYFILE.read_text(encoding="utf-8")
    text, count = re.subn(
        r"^\{\n\temail \{\$ACME_EMAIL\}\n",
        f"{{\n\temail {{$ACME_EMAIL}}\n\tadmin off\n\tauto_https off\n\thttp_port {port}\n",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit("probe: the global options block no longer starts with `email {$ACME_EMAIL}`")
    text, sites = re.subn(r"^(\S*\{\$[A-Z_]+_DOMAIN\}) \{$", r"http://\1 {", text, flags=re.MULTILINE)
    if sites != 3:
        raise SystemExit(f"probe: expected 3 site blocks (site, www, ops), found {sites}")
    return text


@contextmanager
def running_caddy(
    caddy: str,
    workdir: Path,
    api_port: int,
    next_port: int,
    extra_env: dict[str, str] | None = None,
) -> Iterator[tuple[int, Path, Path]]:
    port = free_port()
    config = workdir / "Caddyfile"
    config.write_text(probe_caddyfile(port), encoding="utf-8")
    media = workdir / "media"
    media.mkdir()
    (media / "a.txt").write_text("media", encoding="utf-8")
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(workdir),
        "XDG_DATA_HOME": str(workdir / "xdg"),
        "XDG_CONFIG_HOME": str(workdir / "xdg"),
        "ACME_EMAIL": "probe@example.invalid",
        "API_UPSTREAM": f"127.0.0.1:{api_port}",
        "FRONTEND_UPSTREAM": f"127.0.0.1:{next_port}",
        "MEDIA_ROOT": str(media),
        "OPS_ALLOWED_IPS": OPS_ALLOWED,
        "MEDIA_BACKEND": "disk",
        **HOSTS,
        **(extra_env or {}),
    }
    out, err = workdir / "caddy.out", workdir / "caddy.err"
    with out.open("wb") as stdout, err.open("wb") as stderr:
        process = subprocess.Popen(  # noqa: S603 - the caddy binary the caller names, fixed arguments
            [caddy, "run", "--config", str(config), "--adapter", "caddyfile"],
            env=env,
            stdout=stdout,
            stderr=stderr,
        )
        try:
            deadline = time.monotonic() + 15
            while True:
                if process.poll() is not None:
                    raise SystemExit("probe: caddy exited:\n" + err.read_text(encoding="utf-8")[-2000:])
                try:
                    with closing(socket.create_connection(("127.0.0.1", port), timeout=0.5)):
                        break
                except OSError:
                    if time.monotonic() > deadline:
                        raise SystemExit("probe: caddy did not listen within 15 s") from None
                    time.sleep(0.1)
            yield port, out, err
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@dataclass
class Answer:
    status: int
    headers: dict[str, str]
    body: bytes
    all_headers: list[tuple[str, str]] = field(default_factory=list)

    def values(self, name: str) -> list[str]:
        return [value for key, value in self.all_headers if key.lower() == name.lower()]


def request(
    port: int,
    host: str,
    method: str,
    path: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    source: str | None = None,
) -> Answer:
    connection = http.client.HTTPConnection(
        "127.0.0.1", port, timeout=20, source_address=(source, 0) if source else None
    )
    try:
        try:
            connection.request(method, path, body=body, headers={"Host": host, **(headers or {})})
        except (BrokenPipeError, ConnectionResetError):
            # The edge answered (413) and closed while the body was still being sent: read that answer.
            pass
        try:
            response = connection.getresponse()
        except (ConnectionResetError, http.client.RemoteDisconnected):
            return Answer(413 if body and len(body) > MIB else 0, {}, b"")
        raw = response.getheaders()
        return Answer(response.status, {k.lower(): v for k, v in raw}, response.read(), raw)
    finally:
        connection.close()


class Probe:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passed = 0

    def check(self, condition: bool, message: str) -> None:
        if condition:
            self.passed += 1
        else:
            self.failures.append(message)


def adapted_servers(caddy: str, workdir: Path) -> list[dict[str, object]]:
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(workdir),
        "XDG_DATA_HOME": str(workdir / "xdg"),
        "XDG_CONFIG_HOME": str(workdir / "xdg"),
        "ACME_EMAIL": "probe@example.invalid",
        "SITE_DOMAIN": "example.com",
        "OPS_DOMAIN": "ops.example.com",
        "OPS_ALLOWED_IPS": "192.0.2.10/32 198.51.100.0/24",
    }
    result = subprocess.run(  # noqa: S603 - the caddy binary the caller names, fixed arguments
        [caddy, "adapt", "--config", str(CADDYFILE), "--adapter", "caddyfile"],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    config = json.loads(result.stdout.splitlines()[0])
    servers: dict[str, dict[str, object]] = config["apps"]["http"]["servers"]
    return list(servers.values())


def slow_post(port: int, host: str, path: str, upstream: Upstream) -> list[str]:
    """Send the headers and 10 of 1000 body bytes and idle for a second: the paths the upstream received
    meanwhile (the connection is still open, the body incomplete)."""
    before = len(upstream.paths())
    with closing(socket.create_connection(("127.0.0.1", port), timeout=5)) as sock:
        head = (
            f"POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n"
            "Content-Length: 1000\r\n\r\n"
        )
        sock.sendall(head.encode() + b"{" + b" " * 9)
        time.sleep(1.0)
        return upstream.paths()[before:]


OPS_CSP_REQUIRED = (
    "default-src 'none'",
    "script-src 'self' 'unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    "base-uri 'none'",
)


def check_ops_host(probe: Probe, port: int, ops: str, upstream: Upstream) -> None:
    """The ops console host: allow-list first, then only /django-admin* and /static/* reach Django; /media/
    (the console's image previews) is served from the volume; a professional's photo upload fits the body
    limit."""
    login = request(port, ops, "GET", "/django-admin/login/", headers={"X-Forwarded-For": "198.51.100.7"})
    probe.check(login.status == 200, f"ops: allowed address, login page expected 200, got {login.status}")
    probe.check("/django-admin/login/" in upstream.paths(), "ops: the login page did not reach the upstream")
    with upstream.lock:
        seen = [entry for entry in upstream.requests if entry.path == "/django-admin/login/"]
    probe.check(
        bool(seen) and seen[-1].headers.get("X-Forwarded-For") == "127.0.0.1",
        "ops: X-Forwarded-For must be the TCP peer only (a spoofed hop reached Django)",
    )
    csp = login.headers.get("content-security-policy", "")
    for directive in OPS_CSP_REQUIRED:
        probe.check(directive in csp, f"ops: Content-Security-Policy lacks {directive!r}: {csp!r}")
    probe.check(
        not re.search(r"https?:|\*", csp), f"ops: Content-Security-Policy allows another origin: {csp!r}"
    )
    probe.check(
        login.values("X-Frame-Options") == ["DENY"], f"ops: X-Frame-Options {login.values('X-Frame-Options')}"
    )
    for name, expected in (
        ("x-content-type-options", "nosniff"),
        ("referrer-policy", "same-origin"),
        ("x-robots-tag", "noindex, nofollow"),
    ):
        probe.check(login.headers.get(name) == expected, f"ops: {name} expected {expected!r}")
    probe.check("camera=()" in login.headers.get("permissions-policy", ""), "ops: Permissions-Policy missing")
    static = request(port, ops, "GET", "/static/unfold/css/styles.css")
    probe.check(static.status == 200, f"ops: /static/ expected to reach Django, got {static.status}")
    root = request(port, ops, "GET", "/")
    probe.check(
        root.status == 302 and root.headers.get("location") == "/django-admin/",
        f"ops: / expected 302 to /django-admin/, got {root.status} {root.headers.get('location')}",
    )
    before = len(upstream.paths())
    media = request(port, ops, "GET", "/media/a.txt")
    probe.check(
        media.status == 200
        and media.body == b"media"
        and media.headers.get("x-content-type-options") == "nosniff",
        f"ops: /media/ (the console's image previews) expected 200 with nosniff, got {media.status}",
    )
    probe.check("/media/a.txt" not in upstream.paths()[before:], "ops: /media/ reached the upstream")
    photo = request(
        port, ops, "POST", "/django-admin/professionals/professional/add/", body=b"x" * (5 * MIB + MIB // 2)
    )
    probe.check(
        photo.status == 200, f"ops: a 5.5 MiB photo upload expected to reach Django, got {photo.status}"
    )
    too_big = request(
        port, ops, "POST", "/django-admin/professionals/professional/add/", body=b"x" * (7 * MIB)
    )
    probe.check(too_big.status == 413, f"ops: a 7 MiB body expected 413, got {too_big.status}")
    for path in ("/api/v1/health/", "/api/v1/admin/auth/me/", "/admin"):
        before = len(upstream.paths())  # the other hosts' checks may have sent the same path legitimately
        other = request(port, ops, "GET", path)
        probe.check(
            other.status == 404 and other.body == b"",
            f"ops: {path} expected an empty 404, got {other.status}",
        )
        probe.check(path not in upstream.paths()[before:], f"ops: {path} reached the upstream")
    request(port, ops, "GET", f"/django-admin/accounts/customer/?q={SECRETS['ops_phone']}")
    before = len(upstream.paths())
    for path in ("/django-admin/login/", "/", "/static/unfold/css/styles.css", "/media/a.txt"):
        denied = request(port, ops, "GET", path, source=OUTSIDE_ADDRESS)
        probe.check(
            denied.status == 404 and denied.body == b"",
            f"ops: {path} from an address outside OPS_ALLOWED_IPS expected an empty 404, got {denied.status}",
        )
        probe.check(
            "content-security-policy" in denied.headers, f"ops: the 404 of {path} lacks the security headers"
        )
    probe.check(len(upstream.paths()) == before, "ops: a request from outside the allow-list reached Django")


def check_object_storage_media(probe: Probe, port: int, host: str, label: str, storage: Upstream) -> None:
    """MEDIA_BACKEND=object-storage: /media/* is fetched from /glowderma-media/media/... and never from anywhere
    else in the bucket, and only by GET and HEAD. ``label`` names the host in messages."""
    is_ops = label == "ops"
    with storage.lock:
        storage.requests.clear()
    answer = request(
        port, host, "GET", "/media/products/1/a.webp?list-type=2",
        headers={"Authorization": "AWS4-HMAC-SHA256 probe", "X-Amz-Date": "20260101T000000Z"},
    )
    probe.check(
        answer.status == 200 and answer.body == STORED_BODY,
        f"{label} storage: GET /media/products/1/a.webp expected 200 from the storage, got {answer.status}",
    )
    with storage.lock:
        seen = list(storage.requests)
    probe.check(
        [entry.path for entry in seen] == [STORED_PATH],
        f"{label} storage: the storage must see exactly {STORED_PATH} (query dropped), saw {[e.path for e in seen]}",
    )
    headers = seen[0].headers if seen else {}
    probe.check(
        headers.get("Host") == f"127.0.0.1:{storage.port}",
        f"{label} storage: Host header to the storage was {headers.get('Host')!r}",
    )
    probe.check(
        not any(key.lower() in ("authorization", "x-amz-date") for key in headers),
        f"{label} storage: a credential or X-Amz-* request header was forwarded",
    )
    probe.check(
        answer.values("Cache-Control") == ["public, max-age=604800"],
        f"{label} storage: Cache-Control {answer.values('Cache-Control')}",
    )
    probe.check(
        answer.values("Content-Type") == ["image/webp"], f"{label} storage: Content-Type {answer.values('Content-Type')}"
    )
    if not is_ops:  # the ops host's media block carries Cache-Control only (its CSP is the console's own)
        probe.check(
            answer.values("X-Content-Type-Options") == ["nosniff"],
            f"{label} storage: nosniff {answer.values('X-Content-Type-Options')}",
        )
        probe.check(
            answer.values("Content-Security-Policy") == ["default-src 'none'; img-src 'self'; sandbox"],
            f"{label} storage: Content-Security-Policy {answer.values('Content-Security-Policy')}",
        )
    leaked = [key for key, _ in answer.all_headers if key.lower() == "server" or key.lower().startswith("x-amz-")]
    probe.check(not leaked, f"{label} storage: Server / X-Amz-* headers leaked to the client: {leaked}")

    with storage.lock:
        storage.requests.clear()
    missing = request(port, host, "GET", "/media/products/1/missing.webp")
    probe.check(missing.status == 404, f"{label} storage: a missing object expected 404, got {missing.status}")
    broken = request(port, host, "GET", "/media/products/1/boom.webp")
    # An error answer is never cached for a week and carries no storage body or header.
    for what, answer, status in (("missing object", missing, 404), ("storage 500", broken, 500)):
        probe.check(answer.status == status, f"{label} storage: {what} expected {status}, got {answer.status}")
        probe.check(
            answer.values("Cache-Control") == ["no-store"],
            f"{label} storage: {what} Cache-Control {answer.values('Cache-Control')}",
        )
        probe.check(b"Error" not in answer.body and b"NoSuchKey" not in answer.body, f"{label} storage: {what} body leaked")
        probe.check(
            not [k for k, _ in answer.all_headers if k.lower() == "server" or k.lower().startswith("x-amz-")],
            f"{label} storage: {what} leaked storage headers",
        )
    head = request(port, host, "HEAD", "/media/products/1/a.webp")
    probe.check(
        head.status == 200 and head.body == b"", f"{label} storage: HEAD expected 200 without a body, got {head.status}"
    )
    with storage.lock:
        head_seen = [(entry.method, entry.path) for entry in storage.requests]
    probe.check(
        head_seen[-1:] == [("HEAD", STORED_PATH)], f"{label} storage: HEAD reached the storage as {head_seen[-1:]}"
    )

    # Only GET and HEAD go upstream.
    with storage.lock:
        storage.requests.clear()
    for method in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS"):
        body = b"x" if method in ("POST", "PUT", "PATCH") else None
        refused = request(port, host, method, "/media/products/1/a.webp", body=body)
        probe.check(refused.status == 405, f"{label} storage: {method} /media/... expected 405, got {refused.status}")
        probe.check(
            refused.values("Cache-Control") == ["no-store"],
            f"{label} storage: {method} 405 Cache-Control {refused.values('Cache-Control')}",
        )
    probe.check(not storage.paths(), f"{label} storage: a write method reached the storage: {storage.paths()}")

    # Listings and traversal: the storage is never asked for anything outside /glowderma-media/media/<object>.
    with storage.lock:
        storage.requests.clear()
    # Directory-like paths and backslashes are refused at the edge. Caddy resolves dot-dot segments (raw or
    # percent-encoded) in the request path itself, so those can never climb out of /media or past the bucket
    # prefix; what the storage actually receives is asserted below. Their status is whatever the clean path
    # deserves (Next for one that left /media, the storage's 404 or 200 for one inside it).
    refused_paths = (
        "/media/", "/media/?list-type=2", "/media/products/", "/media//", "/media/products" + chr(92) + "..",
        "/media/a" + chr(92) + "b",
        # Decoded characters that would become a query, a fragment, a NUL or a second decoding upstream.
        "/media/products/1/a.webp%3Flist-type=2", "/media/products/1/a.webp%3Facl", "/media/products/1/a.webp%23x",
        "/media/products/1/a.webp%00", "/media/%252e%252e/x", "/media/products/1/a.webp%253Facl",
        "/media/products/%252e%252e/1/a.webp", "/media/products%252f..%252f1/a.webp",
    )
    for path in refused_paths:
        answer = request(port, host, "GET", path)
        probe.check(answer.status == 404, f"{label} storage: GET {path} expected 404, got {answer.status}")
        probe.check(
            answer.values("Cache-Control") == ["no-store"],
            f"{label} storage: GET {path} 404 Cache-Control {answer.values('Cache-Control')}",
        )
    escaping_paths = (
        "/media/../x", "/media/%2e%2e/x", "/media/%2E%2E/x", "/media/..%2fother-bucket/x",
        "/media/..%2Fother-bucket/x", "/media/products/../../x", "/media/a/%2e%2e%2f%2e%2e/other-bucket/x",
        "/media/.%2e/x", "/media/products/..", "/media/..", "/media/..%5cother-bucket/x",
        "/media/products/../products/1/a.webp", "/media/%2e%2e/media/products/1/a.webp",
        "/media/..%2fmedia/products/1/a.webp", "/media/products/%2E%2E/1/a.webp", "/media/products%5c..%5c1/a.webp",
    )
    for path in escaping_paths:
        request(port, host, "GET", path)
    for path in storage.paths():
        # The raw request target the storage received: no query, no fragment, no NUL, no (double) encoded dot-dot.
        segments = unquote(unquote(path.split("?")[0])).replace("\\", "/").split("/")
        probe.check(
            "#" not in path and "%00" not in path.lower() and "%3f" not in path.lower() and "%25" not in path.lower(),
            f"{label} storage: the storage received a suspicious target {path!r}",
        )
        probe.check(
            path.startswith(f"/{BUCKET}/media/") and ".." not in segments and "?" not in path and not path.endswith("/")
            and chr(92) not in unquote(path),
            f"{label} storage: the storage was asked for {path!r}, outside /{BUCKET}/media/",
        )
    # The object is still served afterwards.
    again = request(port, host, "GET", "/media/products/1/a.webp")
    probe.check(again.status == 200, f"{label} storage: object unreachable after the refused requests ({again.status})")


def run(caddy: str) -> Probe:
    probe = Probe()
    django, nxt = Upstream(), Upstream()
    django_server, next_server = stub_server(django), stub_server(nxt)
    site, www, ops = HOSTS["SITE_DOMAIN"], "www.site.test", HOSTS["OPS_DOMAIN"]
    with tempfile.TemporaryDirectory(prefix="edge-probe-") as tmp:
        workdir = Path(tmp)
        for server_config in adapted_servers(caddy, workdir):
            probe.check(
                server_config.get("read_timeout") == 60_000_000_000
                and server_config.get("read_header_timeout") == 10_000_000_000,
                "server timeouts: read_body 60s / read_header 10s expected, got "
                f"{server_config.get('read_timeout')} / {server_config.get('read_header_timeout')} ns",
            )
        api_port, next_port = int(django_server.server_address[1]), int(next_server.server_address[1])
        with running_caddy(caddy, workdir, api_port, next_port) as (port, out, err):
            # Same origin: /api/v1/* goes to Django, everything else to Next.
            for path in ("/api/v1/health/", "/api/v1/catalog/products/", "/api/v1/auth/refresh/"):
                answer = request(port, site, "GET", path, headers={"X-Forwarded-For": "203.0.113.9"})
                probe.check(answer.status == 200, f"GET {path}: expected 200, got {answer.status}")
                probe.check(path in django.paths(), f"GET {path}: did not reach Django")
                probe.check(path not in nxt.paths(), f"GET {path}: reached Next")
            for path in ("/", "/ru/katalog", "/admin", "/admin/orders", "/api/shop/auth/refresh?next=/",
                         "/api/revalidate", "/healthz", "/_next/static/x.js", "/api/v1x", "/apix"):
                answer = request(port, site, "GET", path)
                probe.check(answer.status == 200, f"GET {path}: expected 200 from Next, got {answer.status}")
                probe.check(path in nxt.paths(), f"GET {path}: did not reach Next")
                probe.check(path not in django.paths(), f"GET {path}: reached Django")
            # Provider callbacks and POS reach Django, query string intact.
            callbacks = [
                "/api/v1/webhooks/click/prepare/",
                "/api/v1/webhooks/payme/",
                f"/api/v1/webhooks/bts/?token={SECRETS['bts_token']}",
                "/api/v1/pos/cashback/resolve-qr/",
            ]
            for path in callbacks:
                answer = request(
                    port, site, "POST", path, body=b"{}",
                    headers={
                        "Content-Type": "application/json",
                        "X-GD-Webhook-Token": SECRETS["bts_header"],
                        "X-GD-Internal-Secret": SECRETS["internal"],
                        "X-Forwarded-For": "203.0.113.9",
                    },
                )
                probe.check(answer.status == 200, f"POST {path}: expected 200 from Django, got {answer.status}")
                probe.check(path in django.paths(), f"POST {path}: Django did not see it intact")
            with django.lock, nxt.lock:
                forwarded = {seen.headers.get("X-Forwarded-For") for seen in django.requests + nxt.requests}
            probe.check(forwarded == {"127.0.0.1"}, f"X-Forwarded-For must be the TCP peer only, got {forwarded}")
            # Staff-only Django surfaces never leave the edge.
            for path in ("/api/v1/admin/auth/me/", "/api/v1/admin", "/api/v1/schema/", "/api/v1/docs/",
                         "/api/v1/dev/payments/1/simulate/", "/django-admin/", "/django-admin"):
                answer = request(port, site, "GET", path)
                probe.check(answer.status == 404, f"GET {path}: expected 404 at the edge, got {answer.status}")
                probe.check(path not in django.paths() + nxt.paths(), f"GET {path} reached an upstream")
            # Body limits: 1 MiB on callbacks/POS, 6 MiB on the API, 7 MB on Next (Server Action uploads).
            big = request(port, site, "POST", "/api/v1/webhooks/payme/", body=b"x" * (MIB + 1))
            probe.check(big.status == 413, f"webhook body of 1 MiB + 1: expected 413, got {big.status}")
            upload = request(port, site, "POST", "/api/v1/customer/me/avatar/", body=b"x" * (5 * MIB + MIB // 2))
            probe.check(upload.status == 200, f"API body of 5.5 MiB: expected 200, got {upload.status}")
            too_big = request(port, site, "POST", "/api/v1/customer/me/avatar/", body=b"x" * (6 * MIB + 1))
            probe.check(too_big.status == 413, f"API body of 6 MiB + 1: expected 413, got {too_big.status}")
            action = request(port, site, "POST", "/admin/products", body=b"x" * (6 * MIB))
            probe.check(action.status == 200, f"Next body of 6 MiB: expected 200, got {action.status}")
            # Response headers on every host.
            for host, path in ((site, "/"), (site, "/api/v1/health/"), (www, "/x?y=1"), (ops, "/django-admin/login/")):
                answer = request(port, host, "GET", path)
                probe.check("server" not in answer.headers, f"{host}{path}: Server header present")
                probe.check("via" not in answer.headers, f"{host}{path}: Via header present")
                probe.check(
                    answer.headers.get("strict-transport-security") == "max-age=31536000",
                    f"{host}{path}: Strict-Transport-Security missing",
                )
            redirect = request(port, www, "GET", "/x?y=1")
            probe.check(
                redirect.status == 308 and redirect.headers.get("location") == f"https://{site}/x?y=1",
                f"www: expected 308 to the apex, got {redirect.status} {redirect.headers.get('location')}",
            )
            before = len(django.paths()) + len(nxt.paths())
            media = request(port, site, "GET", "/media/a.txt")
            probe.check(
                media.status == 200 and media.body == b"media" and media.headers.get("x-content-type-options") == "nosniff",
                f"/media/: expected 200 with nosniff, got {media.status}",
            )
            probe.check(len(django.paths()) + len(nxt.paths()) == before, "/media/ reached an upstream")
            check_ops_host(probe, port, ops, django)
            # Personal data and OAuth values in admin URLs and their Referer.
            request(port, site, "GET", f"/admin/orders?q={SECRETS['phone']}",
                    headers={"Referer": f"http://{site}/admin/customers?q={SECRETS['referer_phone']}"})
            request(port, site, "GET",
                    f"/admin/auth/oauth/google/callback?code={SECRETS['oauth_code']}&state={SECRETS['oauth_state']}")
            # A trickling client: the edge holds the request, Django never sees it.
            for path in (f"/api/v1/webhooks/bts/?token={SECRETS['slow_token']}", "/api/v1/auth/login/"):
                arrived = slow_post(port, site, path, django)
                probe.check(not arrived, f"slow POST {path.split('?')[0]}: reached Django before its body was complete")
            # Django goes away (api restarting): the 502 error line must be redacted as well.
            django.down = True
            down = request(port, site, "POST", f"/api/v1/webhooks/bts/?token={SECRETS['down_token']}", body=b"{}",
                           headers={"X-GD-Webhook-Token": SECRETS["down_header"]})
            probe.check(down.status == 502, f"Django down: expected 502, got {down.status}")
            request(port, site, "GET", f"/api/v1/customers/?q={SECRETS['down_phone']}")
            time.sleep(0.5)
        storage = Upstream(
            objects={STORED_PATH: STORED_BODY}, errors={f"/{BUCKET}/media/products/1/boom.webp": 500}
        )
        storage_server = stub_server(storage)
        object_env = {
            "MEDIA_BACKEND": "object-storage",
            "OBJECT_STORAGE_UPSTREAM": f"127.0.0.1:{storage.port}",
            "OBJECT_STORAGE_BUCKET": BUCKET,
            "S3_LOCATION": "media",
            "MEDIA_ROOT": str(workdir / "unused-media-root"),
        }
        object_dir = workdir / "object-storage-mode"
        object_dir.mkdir()
        with running_caddy(caddy, object_dir, api_port, next_port, object_env) as (object_port, _, _):
            check_object_storage_media(probe, object_port, site, "site", storage)
            check_object_storage_media(probe, object_port, ops, "ops", storage)
            ops_outside = request(object_port, ops, "GET", "/media/products/1/a.webp", source=OUTSIDE_ADDRESS)
            probe.check(
                ops_outside.status == 404 and ops_outside.body == b"",
                f"ops storage: an address outside OPS_ALLOWED_IPS expected an empty 404, got {ops_outside.status}",
            )
        storage_server.shutdown()
        django_server.shutdown()
        next_server.shutdown()
        logs = {"access log (stdout)": out.read_text(encoding="utf-8"), "error log (stderr)": err.read_text("utf-8")}
    for name, text in logs.items():
        for label, value in SECRETS.items():
            probe.check(value not in text, f"{name} contains the {label} value")
    probe.check("?REDACTED" in logs["access log (stdout)"], "access log: no redacted query string found")
    probe.check("/api/v1/webhooks/bts/?REDACTED" in logs["error log (stderr)"],
                "error log: the 502 of the BTS webhook was not logged (redacted)")
    return probe


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else None)
    parser.add_argument("--caddy", default=os.environ.get("CADDY_BIN", "caddy"), help="caddy binary")
    args = parser.parse_args(argv)
    probe = run(args.caddy)
    for failure in probe.failures:
        print(f"FAIL {failure}")
    print(f"edge probe: {probe.passed} checks passed, {len(probe.failures)} failed")
    return 1 if probe.failures else 0


if __name__ == "__main__":
    sys.exit(main())
