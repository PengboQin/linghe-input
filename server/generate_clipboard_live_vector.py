"""Regenerate public synthetic cross-language vectors; never loads product state."""
import base64
import hashlib
import json
from pathlib import Path
import uuid
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import clipboard_live as live
from private_input_relay import integer_bytes
from test_clipboard_live import ClipboardLiveTests, b64


def vector():
    case = ClipboardLiveTests('test_wsgi_status_no_body_and_routes_are_separate')
    case.setUp()
    try:
        cert = case.certificate()
        text = 'line one\r\n  line two\n\ntrail  '
        event = case.event(cert, text, event='00000000-0000-4000-8000-000000000092', nonce=bytes(range(12)))
        request = case.batch_request(cert, event, nonce='00000000-0000-4000-8000-000000000093')
        revoke = case.revoke(cert['generation'], cert=cert)
        revoke['nonce'] = '00000000-0000-4000-8000-000000000094'
        primary = Ed25519PrivateKey.from_private_bytes(base64.b64decode(case.fixture['recipientSeed']))
        revoke['signature'] = b64(primary.sign(live.revoke_header(revoke)))
        key = HKDF(algorithm=hashes.SHA256(), length=32,
                   salt=uuid.UUID(case.group).bytes + integer_bytes(2),
                   info=b'PrivateInput/clipboard-live-key/v1\0' + uuid.UUID(cert['parent']).bytes + base64.b64decode(cert['signingPublic'])).derive(bytes([91]) * 32)
        legacy = json.loads((Path(__file__).resolve().parents[1] / 'fixtures/protocol/secure-message-v1.json').read_text())
        msg = legacy['envelope']
        legacy_key = HKDF(algorithm=hashes.SHA256(), length=32,
                          salt=uuid.UUID(msg['group']).bytes + integer_bytes(msg['epoch']),
                          info=b'PrivateInput/sender-domain-key/v1\0' + uuid.UUID(msg['sender']).bytes + base64.b64decode(legacy['signingPublic']) + bytes([2])).derive(base64.b64decode(legacy['masterKey']))
        from private_input_relay import envelope_bytes
        _, _, _, legacy_header, cipher = envelope_bytes(msg)
        assert ChaCha20Poly1305(legacy_key).decrypt(bytes(4) + integer_bytes(msg['sequence']), cipher, legacy_header) == base64.b64decode(legacy['plaintext'])
        return {'warning': 'PUBLIC SYNTHETIC TEST KEYS ONLY. Never use any key/nonce/identity in production.',
                'serverNow': case.now, 'primarySeed': case.fixture['recipientSeed'], 'delegateSeed': b64(bytes([90]) * 32),
                'senderDomainKey': b64(bytes([91]) * 32), 'liveKey': b64(key), 'plaintextUTF8': b64(text.encode()),
                'certificate': cert, 'certificateCanonicalHex': live.certificate_bytes(cert).hex(),
                'certificateDigestHex': live.certificate_digest(cert).hex(),
                'event': event, 'eventHeaderHex': live.event_header(event).hex(),
                'request': request, 'requestHeaderHex': live.request_header(request).hex(),
                'revoke': revoke, 'revokeHeaderHex': live.revoke_header(revoke).hex(),
                'legacy': {'envelope': msg, 'senderDomainKey': b64(legacy_key), 'signingPublic': legacy['signingPublic'],
                           'headerHex': legacy_header.hex(), 'plaintextUTF8': legacy['plaintext']},
                'capabilities': live.capabilities()}
    finally:
        case.tearDown()


if __name__ == '__main__':
    path = Path(__file__).resolve().parents[1] / 'fixtures/protocol/clipboard-live-v1.json'
    path.write_text(json.dumps(vector(), ensure_ascii=False, indent=2) + '\n')
    print(str(path))
