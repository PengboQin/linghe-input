"""Pure synthetic Python/Swift interoperability fixture; no real identities."""
import base64
import json
from pathlib import Path
import tempfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from activity_archive.service import MemoryAuthority, encode
from .service import LearningStore, LearningApplication, canonical


def generate():
    now = 1792600000
    group = '11111111-1111-4111-8111-111111111111'
    device = '22222222-2222-4222-8222-222222222222'
    install = '33333333-3333-4333-8333-333333333333'
    key = Ed25519PrivateKey.from_private_bytes(bytes(range(32)))
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    authority = MemoryAuthority(); authority.put(group, {device: (public, 3)})
    with tempfile.TemporaryDirectory(prefix='cloud-learning-wire-') as temp:
        store = LearningStore(Path(temp) / 'learning.sqlite', clock=lambda: now)
        app = LearningApplication(store, authority, clock=lambda: now)
        nonce = 0
        def call(op, body):
            nonlocal nonce
            nonce += 1; raw = encode(body)
            envelope = {'version': 1, 'group': group, 'sender': device, 'nonce': '44444444-4444-4444-8444-' + str(nonce).zfill(12), 'issuedAt': now, 'operation': op, 'body': base64.b64encode(raw).decode()}
            envelope['signature'] = base64.b64encode(key.sign(canonical(envelope, raw))).decode()
            return app.dispatch(encode(envelope))
        disabled = call(1, {})
        call(2, {'expected_version': 0, 'enabled': True})
        status = call(3, {'expected_version': 0, 'enabled': True, 'installation_id': install})
        events = []
        for i, (reading, text, layout) in enumerate([('hao', '好', 'pinyin26'), ('tao bao', '淘宝', 't9')], 1):
            events.append({'event_id': '55555555-5555-4555-8555-' + str(i).zfill(12), 'device_seq': i, 'kind': 'confirm', 'reading': reading, 'text': text, 'layout': layout, 'term_generation': 0, 'observed_at': now})
        receipt = call(4, {'generation': 1, 'consent_version': 1, 'installation_id': install, 'events': events})
        store.worker_tick(authority, force=True)
        pull = call(5, {'generation': 1, 'from_version': 0})
        fixture = {'fixture_kind': 'synthetic_only', 'group': group, 'device': device, 'installation': install, 'issued_at': now, 'public_key': base64.b64encode(public).decode(), 'disabled_status': disabled, 'status': status, 'events': events, 'receipt': receipt, 'pull': pull}
        store.close()
        return fixture


if __name__ == '__main__':
    print(json.dumps(generate(), ensure_ascii=False, sort_keys=True, indent=2))
