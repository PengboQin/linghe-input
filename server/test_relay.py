import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.request
import uuid
from wsgiref.simple_server import make_server, WSGIRequestHandler
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from private_input_relay import Relay, RelayError, encoded, envelope_bytes, identifier, integer_bytes, membership_bytes, pair_request_bytes, strict_json
from expire_relay import expire_existing

ROOT = Path(__file__).resolve().parents[1]


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="PrivateInput-Relay-")
        self.path = Path(self.temp.name) / "relay.sqlite"
        self.now = 1010
        self.app = Relay(self.path, clock=lambda: self.now)
        self.fixture = json.loads((ROOT / "fixtures/protocol/relay-membership-v1.json").read_text())
        self.message = json.loads((ROOT / "fixtures/protocol/secure-message-v1.json").read_text())["envelope"]
        self.group = self.fixture["paired"]["group"]
        self.recipient = self.fixture["paired"]["members"][1]["device"]
        self.app.register(self.fixture["initial"]); self.app.update(self.group, self.fixture["paired"])

    def tearDown(self):
        self.app.db.close(); self.temp.cleanup()

    def request(self, operation, payload=None, sender=None, seed=None):
        sender = sender or self.recipient
        seed = seed or self.fixture["recipientSeed"]
        body = b"" if payload is None else encoded(payload)
        nonce = str(uuid.uuid4()).upper()
        header = (b"PrivateInput/relay-request/v1\0" + b"\x01" + uuid.UUID(self.group).bytes
                  + uuid.UUID(sender).bytes + uuid.UUID(nonce).bytes + integer_bytes(self.now)
                  + bytes([operation]) + hashlib.sha256(body).digest())
        signature = Ed25519PrivateKey.from_private_bytes(base64.b64decode(seed)).sign(header)
        return {"version": 1, "group": self.group, "sender": sender, "nonce": nonce, "issuedAt": self.now,
                "operation": operation, "body": base64.b64encode(body).decode(), "signature": base64.b64encode(signature).decode()}

    def wsgi(self, method, path, body):
        data = encoded(body); status = []
        env = {"REQUEST_METHOD": method, "PATH_INFO": path, "CONTENT_LENGTH": str(len(data)), "wsgi.input": io.BytesIO(data), "REMOTE_ADDR": "127.0.0.1"}
        output = b"".join(self.app(env, lambda value, _: status.append(value)))
        return int(status[0].split()[0]), strict_json(output)

    def pairing(self):
        seed = bytes([73]) * 32
        public = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        exchange = X25519PrivateKey.from_private_bytes(bytes([74]) * 32).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        b64 = lambda data: base64.b64encode(data).decode()
        member = {"device": str(uuid.uuid4()).upper(), "signingPublic": b64(public), "exchangePublic": b64(exchange), "permissions": 3}
        request = {"version": 1, "session": str(uuid.uuid4()).upper(), "member": member,
                   "challenge": b64(bytes([75]) * 32), "issuedAt": self.now, "expiresAt": self.now + 90}
        body = (b"PrivateInput/pair-request/v1\0\x01" + uuid.UUID(request["session"]).bytes
                + uuid.UUID(member["device"]).bytes + public + exchange + bytes([75]) * 32
                + integer_bytes(request["issuedAt"]) + integer_bytes(request["expiresAt"]))
        request["signature"] = b64(Ed25519PrivateKey.from_private_bytes(seed).sign(body))
        return request, b64(seed)

    def challenge(self, request):
        b64 = lambda data: base64.b64encode(data).decode()
        proposed = copy.deepcopy(self.fixture["paired"])
        proposed["revision"] += 1; proposed["epoch"] += 1
        proposed["members"].append(request["member"]); proposed["signature"] = ""
        template = {"version": 1, "purpose": 1, "recipient": request["member"]["device"],
                    "ephemeralPublic": b64(bytes([76]) * 32), "context": b64(pair_request_bytes(request, self.now)[3]),
                    "membership": proposed, "issuedAt": self.now, "expiresAt": request["expiresAt"], "sealedKey": ""}
        self.sign_key_header(template)
        return {"session": request["session"], "challenge": {"template": template}}

    def sign_key_header(self, template):
        member = next(m for m in template["membership"]["members"] if m["device"] == template["recipient"])
        header = (b"PrivateInput/wrapped-group-key/v1\0\x01" + bytes([template["purpose"]])
                  + uuid.UUID(template["recipient"]).bytes + base64.b64decode(member["exchangePublic"])
                  + base64.b64decode(template["ephemeralPublic"]) + base64.b64decode(template["context"])
                  + membership_bytes(template["membership"], require_signature=False)[2]
                  + integer_bytes(template["issuedAt"]) + integer_bytes(template["expiresAt"])
                  + base64.b64decode(template["sealedKey"]))
        template["signature"] = base64.b64encode(Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture["ownerSeed"])).sign(header)).decode()

    def testPendingRequestsRequireIndependentOwnerRootAuthority(self):
        request, seed = self.pairing()
        self.app.rpc(self.group, self.request(7, request, sender=request["member"]["device"], seed=seed))
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", self.request(5))[0], 403)
        owner = self.fixture["paired"]["ownerID"]
        wrong_key = self.request(5, sender=owner, seed=self.fixture["senderSeed"])
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", wrong_key)[0], 401)
        response = self.app.rpc(self.group, self.request(5, sender=owner, seed=self.fixture["ownerSeed"]))
        self.assertEqual(response["requests"], [request])

    def testPairSessionProofAndReplayCannotReadAnotherSession(self):
        request, seed = self.pairing(); sender = request["member"]["device"]
        submission = self.request(7, request, sender=sender, seed=seed)
        self.app.rpc(self.group, submission)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", submission)[0], 409)
        # Same inner request with a fresh authenticated nonce is an idempotent retry.
        self.assertTrue(self.app.rpc(self.group, self.request(7, request, sender=sender, seed=seed))["accepted"])
        value = self.challenge(request); self.app.store_challenge(self.group, value)
        own = self.app.rpc(self.group, self.request(6, {"session": request["session"]}, sender=sender, seed=seed))
        self.assertEqual(own["challenge"], value["challenge"])
        other = self.request(6, {"session": request["session"]})
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", other)[0], 404)
        forged = self.request(6, {"session": request["session"]}, sender=sender, seed=self.fixture["recipientSeed"])
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", forged)[0], 401)
        self.now = request["expiresAt"]
        expired = self.request(6, {"session": request["session"]}, sender=sender, seed=seed)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", expired)[0], 404)

    def testPublicChallengeIsBoundButCannotAuthorizeMembershipOrReleaseKeys(self):
        request, seed = self.pairing(); sender = request["member"]["device"]
        self.app.rpc(self.group, self.request(7, request, sender=sender, seed=seed))
        value = self.challenge(request)
        self.assertTrue(self.app.store_challenge(self.group, value)["accepted"])
        template = value["challenge"]["template"]
        self.assertEqual(self.wsgi("PUT", "/v1/groups/" + self.group + "/membership", template["membership"])[0], 400)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/keys", template)[0], 400)
        tampered = copy.deepcopy(value); tampered["challenge"]["template"]["context"] = base64.b64encode(bytes([77]) * 32).decode()
        self.sign_key_header(tampered["challenge"]["template"])
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/pair-challenge", tampered)[0], 403)
        leaked = copy.deepcopy(value); leaked["challenge"]["template"]["sealedKey"] = base64.b64encode(bytes([78]) * 60).decode()
        self.sign_key_header(leaked["challenge"]["template"])
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/pair-challenge", leaked)[0], 400)

    def testKeyMailboxIsRecipientScopedAndRejectsChangedOrOldMembership(self):
        state = copy.deepcopy(self.fixture["paired"])
        b64 = lambda data: base64.b64encode(data).decode()
        package = {"version": 1, "purpose": 2, "recipient": self.recipient,
                   "ephemeralPublic": b64(bytes([80]) * 32), "context": b64(bytes(32)), "membership": state,
                   "issuedAt": self.now, "expiresAt": self.now + 60, "sealedKey": b64(bytes([81]) * 60)}
        self.sign_key_header(package); self.app.store_key(self.group, package)
        self.assertEqual(self.app.rpc(self.group, self.request(4))["package"], package)
        sender = self.message["sender"]
        other = self.request(4, sender=sender, seed=self.fixture["senderSeed"])
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", other)[0], 404)
        altered = copy.deepcopy(package); altered["sealedKey"] = b64(bytes([82]) * 60)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/keys", altered)[0], 401)
        old = copy.deepcopy(package); old["membership"] = self.fixture["initial"]
        old["recipient"] = old["membership"]["members"][0]["device"]; self.sign_key_header(old)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/keys", old)[0], 403)

    def testSwiftOwnerStateAndSignedPullRequestInteroperate(self):
        self.app.push(self.group, self.message)
        response = self.app.rpc(self.group, self.fixture["pullRequest"])
        self.assertEqual(response["events"], [self.message])
        with self.assertRaises(RelayError):
            self.app.rpc(self.group, self.fixture["pullRequest"])

    def testPushRetryAfterDeliveryDoesNotCreateClipboardLoop(self):
        self.app.push(self.group, self.message)
        self.assertEqual(len(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"]), 1)
        self.app.rpc(self.group, self.request(3, {"events": [self.message["event"]]}))
        self.assertEqual(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"], [])
        self.app.push(self.group, self.message)
        self.assertEqual(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"], [])

    def testAckCannotDeleteAnotherRecipientsQueue(self):
        self.app.push(self.group, self.message)
        sender = self.message["sender"]
        self.app.rpc(self.group, self.request(3, {"events": [self.message["event"]]}, sender=sender, seed=self.fixture["senderSeed"]))
        self.assertEqual(len(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"]), 1)

    def testUnknownDeviceTamperingAndReplayAreRejected(self):
        fake = self.request(2, {"limit": 2}, sender=str(uuid.uuid4()))
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", fake)[0], 403)
        request = self.request(2, {"limit": 2}); request["body"] = base64.b64encode(b'{"limit":1}').decode()
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", request)[0], 401)
        message = copy.deepcopy(self.message); message["sequence"] += 1
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/events", message)[0], 401)
        request = self.request(2, {"limit": 2})
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", request)[0], 200)
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/rpc", request)[0], 409)

    def testOwnerStateCannotRollbackOrBeChangedByRelay(self):
        self.assertEqual(self.wsgi("PUT", "/v1/groups/" + self.group + "/membership", self.fixture["initial"])[0], 409)
        forged = copy.deepcopy(self.fixture["paired"]); forged["members"][1]["permissions"] = 1
        self.assertEqual(self.wsgi("PUT", "/v1/groups/" + self.group + "/membership", forged)[0], 401)

    def testQueueExpiryRestartAndDatabaseHaveNoPlaintextOrMasterKey(self):
        self.app.push(self.group, self.message)
        self.app.db.close(); self.app = Relay(self.path, clock=lambda: self.now)
        self.assertEqual(len(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"]), 1)
        known = json.loads((ROOT / "fixtures/protocol/secure-message-v1.json").read_text())
        for path in Path(self.temp.name).iterdir():
            data = path.read_bytes()
            self.assertNotIn(base64.b64decode(known["plaintext"]), data)
            self.assertNotIn(base64.b64decode(known["masterKey"]), data)
            self.assertNotIn(known["masterKey"].encode(), data)
        self.now = 1600
        self.assertEqual(self.app.rpc(self.group, self.request(2, {"limit": 2}))["events"], [])
        with self.assertRaises(RelayError):
            self.app.push(self.group, self.message)

    def testStandaloneExpiryWorksWithoutAnyIncomingHTTPRequest(self):
        self.app.push(self.group, self.message)
        self.app.rpc(self.group, self.request(2, {"limit": 2}))
        result = expire_existing(self.path, now=2000)
        self.assertGreater(result["expiredRows"], 0)
        self.assertFalse(result["physicalErasureProven"])
        self.assertEqual(self.app.db.execute("SELECT count(*) FROM messages").fetchone()[0], 0)
        self.assertEqual(self.app.db.execute("SELECT count(*) FROM recipients").fetchone()[0], 0)
        self.assertEqual(self.app.db.execute("SELECT count(*) FROM groups").fetchone()[0], 1)
        self.assertEqual(expire_existing(self.path, now=2000)["expiredRows"], 0)
        missing = self.path.parent / "absent.sqlite"
        with self.assertRaises(FileNotFoundError): expire_existing(missing, now=2000)
        self.assertFalse(missing.exists())

    def testMalformedExtraFieldsAndQuotaFailClosed(self):
        message = copy.deepcopy(self.message); message["plaintext"] = "synthetic secret"
        self.assertEqual(self.wsgi("POST", "/v1/groups/" + self.group + "/events", message)[0], 400)
        with self.assertRaises(RelayError):
            strict_json(b'{"version":1,"version":2}')
        with self.assertRaises(RelayError):
            strict_json(b'{"number":NaN}')
        with self.assertRaises(RelayError):
            strict_json(b'{"number":' + b'9' * 10000 + b'}')
        with self.assertRaises(RelayError):
            strict_json(b'{"number":1.0}')
        for _ in range(240):
            self.app.rate("synthetic-peer")
        with self.assertRaises(RelayError):
            self.app.rate("synthetic-peer")

    def testRealLoopbackHTTPUsesSameSignedCiphertextProtocol(self):
        class Quiet(WSGIRequestHandler):
            def log_message(self, *args):
                pass
        server = make_server("127.0.0.1", 0, self.app, handler_class=Quiet)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = "http://127.0.0.1:" + str(server.server_port) + "/v1/groups/" + self.group
        try:
            request = urllib.request.Request(base + "/events", data=encoded(self.message), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertTrue(strict_json(response.read())["accepted"])
            request = urllib.request.Request(base + "/rpc", data=encoded(self.fixture["pullRequest"]), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(strict_json(response.read())["events"], [self.message])
        finally:
            server.shutdown(); thread.join(timeout=5); server.server_close()


if __name__ == "__main__":
    unittest.main()
