import io
from pathlib import Path
import tempfile
import unittest
from private_input_relay import Relay
from production_wsgi import LocalProxy


class ProductionProxyTests(unittest.TestCase):
    def test_only_local_proxy_can_supply_peer_and_untrusted_xff_is_ignored(self):
        with tempfile.TemporaryDirectory() as temp:
            relay = Relay(Path(temp) / "relay.sqlite")
            app = LocalProxy(relay)
            def call(address, peer, path="/v1/groups"):
                response = []
                app({"REMOTE_ADDR": address, "HTTP_X_PRIVATEINPUT_PEER": peer,
                     "HTTP_X_FORWARDED_FOR": "203.0.113.99", "PATH_INFO": path,
                     "REQUEST_METHOD": "GET" if path == "/healthz" else "POST",
                     "CONTENT_LENGTH": "2", "wsgi.input": io.BytesIO(b'{}')},
                    lambda status, headers: response.append(status))
                return response[0]
            self.assertTrue(call("198.51.100.1", "203.0.113.1").startswith("403"))
            self.assertTrue(call("127.0.0.1", "invalid").startswith("400"))
            self.assertTrue(call("127.0.0.1", "203.0.113.1").startswith("400"))
            self.assertEqual(list(relay.rates), ["203.0.113.1"])
            self.assertTrue(call("127.0.0.1", "", "/healthz").startswith("200"))
            relay.db.close()
