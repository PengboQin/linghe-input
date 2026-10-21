"""Production entry point behind the existing local Caddy proxy only."""
import ipaddress
import os
from private_input_relay import Relay


class LocalProxy:
    def __init__(self, relay):
        self.relay = relay

    def __call__(self, environ, start_response):
        # Caddy overwrites this header using the TCP peer, never a client XFF.
        # The backend binds only to loopback and trusts no other transport.
        if environ.get("REMOTE_ADDR") not in ("127.0.0.1", "::1"):
            start_response("403 Forbidden", [("Content-Type", "application/json")])
            return [b'{"error":"proxy_required"}']
        if environ.get("PATH_INFO") == "/healthz" and environ.get("REQUEST_METHOD") == "GET":
            with self.relay.lock:
                self.relay.db.execute("SELECT 1").fetchone()
            start_response("200 OK", [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
            return [b'{"service":"private-input-relay","ready":true}']
        try:
            peer = str(ipaddress.ip_address(environ.get("HTTP_X_PRIVATEINPUT_PEER", "")))
        except ValueError:
            start_response("400 Bad Request", [("Content-Type", "application/json")])
            return [b'{"error":"peer_required"}']
        forwarded = dict(environ)
        forwarded["REMOTE_ADDR"] = peer
        return self.relay(forwarded, start_response)


def create_app():
    relay = Relay(os.environ["PRIVATE_INPUT_RELAY_DATABASE"])
    # Bound this service's database growth independently of the existing site.
    page_size = relay.db.execute("PRAGMA page_size").fetchone()[0]
    relay.db.execute("PRAGMA max_page_count=" + str(128 * 1024 * 1024 // page_size))
    relay.db.execute("PRAGMA journal_size_limit=8388608")
    relay.db.execute("PRAGMA wal_autocheckpoint=512")
    return LocalProxy(relay)
