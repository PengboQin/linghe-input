import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import unittest
import uuid
from unittest.mock import patch

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
import clipboard_live as live
import test_relay
from private_input_relay import Relay, RelayError, encoded, integer_bytes, membership_canonical, strict_json
from expire_relay import expire_existing


def b64(data):
    return base64.b64encode(data).decode('ascii')


class ClipboardLiveTests(unittest.TestCase):
    setUp = test_relay.RelayTests.setUp
    tearDown = test_relay.RelayTests.tearDown
    request = test_relay.RelayTests.request
    wsgi = test_relay.RelayTests.wsgi

    def certificate(self, parent=None, seed=None, issued=None, generation=None, delegate_seed=None):
        parent = parent or self.recipient
        seed = base64.b64decode(seed or self.fixture['recipientSeed'])
        primary = Ed25519PrivateKey.from_private_bytes(seed)
        self.delegate = Ed25519PrivateKey.from_private_bytes(delegate_seed or bytes([90]) * 32)
        cert = {'version': 1, 'group': self.group, 'parent': parent, 'epoch': 2,
                'generation': generation or '00000000-0000-4000-8000-000000000090',
                'signingPublic': b64(primary.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
                'delegatePublic': b64(self.delegate.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)),
                'issuedAt': self.now if issued is None else issued, 'expiresAt': self.now + live.LEASE,
                'signature': ''}
        cert['signature'] = b64(primary.sign(live.certificate_bytes(cert)))
        return cert

    def event(self, cert, text='line one\r\n  line two\n\ntrail  ', event=None, nonce=None):
        value = {'version': 1, 'group': self.group, 'sender': cert['parent'],
                 'event': event or str(uuid.uuid4()).upper(), 'epoch': cert['epoch'],
                 'issuedAt': self.now, 'expiresAt': self.now + 600,
                 'nonce': b64(nonce or uuid.uuid4().bytes[:12]), 'ciphertext': b64(bytes(16)),
                 'certificate': cert, 'signature': ''}
        sender_key = bytes([91]) * 32
        key = HKDF(algorithm=hashes.SHA256(), length=32,
                   salt=uuid.UUID(self.group).bytes + integer_bytes(cert['epoch']),
                   info=b'PrivateInput/clipboard-live-key/v1\0' + uuid.UUID(cert['parent']).bytes + base64.b64decode(cert['signingPublic'])).derive(sender_key)
        value['ciphertext'] = b64(ChaCha20Poly1305(key).encrypt(base64.b64decode(value['nonce']), text.encode(), live.event_header(value)))
        value['signature'] = b64(self.delegate.sign(live.event_header(value) + base64.b64decode(value['ciphertext'])))
        return value

    def batch_request(self, cert=None, event=None, after=0, limit=32, nonce=None):
        cert = cert or self.certificate()
        body = encoded({'after': after, 'limit': limit, 'publish': event})
        req = {'version': 1, 'group': self.group, 'sender': cert['parent'], 'epoch': cert['epoch'],
               'nonce': nonce or str(uuid.uuid4()).upper(), 'issuedAt': self.now,
               'certificate': cert, 'body': b64(body), 'signature': ''}
        req['signature'] = b64(self.delegate.sign(live.request_header(req)))
        return req

    def batch(self, cert=None, event=None, after=0, limit=32):
        return live.batch(self.app, self.batch_request(cert, event, after, limit))

    def revoke(self, generation, seed=None, cert=None):
        cert = cert or self.certificate()
        value = {'version': 1, 'group': self.group, 'parent': cert['parent'], 'epoch': cert['epoch'],
                 'generation': generation, 'issuedAt': self.now, 'nonce': str(uuid.uuid4()).upper(), 'signature': ''}
        private = Ed25519PrivateKey.from_private_bytes(base64.b64decode(seed or self.fixture['recipientSeed']))
        value['signature'] = b64(private.sign(live.revoke_header(value)))
        return value

    def code(self, fn):
        with self.assertRaises(RelayError) as result:
            fn()
        return result.exception.status, result.exception.code

    def legacy(self, *, event=None, sequence=None, domain=None):
        msg = copy.deepcopy(self.message)
        if event is not None:
            msg['event'] = event
        if sequence is not None:
            msg['sequence'] = sequence
        if domain is not None:
            msg['domain'] = domain
        from private_input_relay import envelope_bytes
        _, _, _, header, cipher = envelope_bytes(msg)
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture['senderSeed']))
        msg['signature'] = b64(key.sign(header + cipher))
        return msg

    def test_ciphertext_publish_persists_and_round_trips_exact_raw_bytes(self):
        cert = self.certificate(); event = self.event(cert)
        result = self.batch(cert, event)
        self.assertEqual(result['accepted'], event['event'])
        self.assertEqual(result['head'], 1)
        self.assertEqual(result['next'], 1)
        self.assertEqual(result['items'][0]['kind'], 'live')
        wire = base64.b64decode(result['items'][0]['wire'])
        self.assertEqual(strict_json(wire), event)
        self.assertNotIn(b'line one', wire)
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=uuid.UUID(self.group).bytes + integer_bytes(2),
                   info=b'PrivateInput/clipboard-live-key/v1\0' + uuid.UUID(cert['parent']).bytes + base64.b64decode(cert['signingPublic'])).derive(bytes([91]) * 32)
        plain = ChaCha20Poly1305(key).decrypt(base64.b64decode(event['nonce']), base64.b64decode(event['ciphertext']), live.event_header(event))
        self.assertEqual(plain, b'line one\r\n  line two\n\ntrail  ')
        self.app.db.close(); self.app = Relay(self.path, clock=lambda: self.now)
        self.assertEqual(self.batch(cert)['items'][0]['wire'], result['items'][0]['wire'])

    def test_request_replay_does_not_publish_twice_and_event_retry_is_idempotent(self):
        cert = self.certificate(); event = self.event(cert)
        req = self.batch_request(cert, event)
        live.batch(self.app, req)
        self.assertEqual(self.code(lambda: live.batch(self.app, req))[1], 'live_request_replay')
        self.assertEqual(self.batch(cert, event)['head'], 1)

    def test_same_event_changed_ciphertext_is_conflict_without_advancing_head(self):
        cert = self.certificate(); event = self.event(cert)
        self.batch(cert, event)
        changed = self.event(cert, 'different', event=event['event'])
        self.assertEqual(self.code(lambda: self.batch(cert, changed)), (409, 'live_event_conflict'))
        self.assertEqual(self.batch(cert)['head'], 1)

    def test_same_crypto_nonce_new_event_is_rejected_but_exact_event_retry_allowed(self):
        cert = self.certificate(); event = self.event(cert, nonce=bytes(range(12)))
        self.batch(cert, event)
        self.assertEqual(self.batch(cert, event)['head'], 1)
        other = self.event(cert, 'other', nonce=bytes(range(12)))
        self.assertEqual(self.code(lambda: self.batch(cert, other))[1], 'live_crypto_nonce_reuse')

    def test_certificate_and_event_expiry_bounds_future_and_oversize(self):
        cert = self.certificate()
        primary = Ed25519PrivateKey.from_private_bytes(base64.b64decode(self.fixture['recipientSeed']))
        over = copy.deepcopy(cert); over['expiresAt'] = over['issuedAt'] + live.LEASE + 1
        self.assertEqual(self.code(lambda: live.certificate_bytes(over))[0], 400)
        future = copy.deepcopy(cert); future['issuedAt'] = self.now + 301
        future['signature'] = b64(primary.sign(live.certificate_bytes(future)))
        self.assertEqual(self.code(lambda: self.batch(future))[1], 'live_certificate_expired')
        expired = copy.deepcopy(cert); expired['issuedAt'] = self.now - 1; expired['expiresAt'] = self.now
        expired['signature'] = b64(primary.sign(live.certificate_bytes(expired)))
        self.assertEqual(self.code(lambda: self.batch(expired))[1], 'live_certificate_expired')
        event = self.event(cert); event['expiresAt'] += 1
        self.assertEqual(self.code(lambda: self.batch(cert, event))[1], 'live_ttl')
        event = self.event(cert); event['ciphertext'] = b64(bytes(65553))
        self.assertEqual(self.code(lambda: self.batch(cert, event))[0], 400)

    def test_current_clipboard_only_member_can_use_feed_but_not_management(self):
        state = copy.deepcopy(self.fixture['paired'])
        next(m for m in state['members'] if m['device'] == self.recipient)['permissions'] = 2
        self.app.db.execute('UPDATE groups SET state=? WHERE id=?', (encoded(state), self.group))
        cert = self.certificate(); self.assertEqual(self.batch(cert)['head'], 0)
        self.assertEqual(self.code(lambda: self.app.rpc(self.group, self.request(8, {})))[0], 403)

    def test_other_group_parent_binding_and_invalid_parent_cert_signature(self):
        cert = self.certificate()
        req = self.batch_request(cert); req['sender'] = self.message['sender']
        self.assertEqual(self.code(lambda: live.batch(self.app, req))[1], 'live_certificate_binding')
        req = self.batch_request(cert); req['group'] = str(uuid.uuid4())
        self.assertEqual(self.code(lambda: live.batch(self.app, req))[1], 'live_certificate_binding')
        bad = copy.deepcopy(cert); bad['signature'] = b64(bytes(64))
        self.assertEqual(self.code(lambda: self.batch(bad))[0], 401)

    def test_mobile_inactivity_is_not_renewed_by_delegated_attempt(self):
        self.app.db.execute("UPDATE device_profiles SET kind='ios',last_seen=?,idle_days=1 WHERE group_id=? AND device=?", (self.now - 86400, self.group, self.recipient))
        self.assertEqual(self.code(lambda: self.batch())[1], 'device_inactive')
        self.assertEqual(self.app.db.execute('SELECT last_seen FROM device_profiles WHERE group_id=? AND device=?', (self.group, self.recipient)).fetchone()[0], self.now - 86400)

    def test_revoke_persists_restart_and_cannot_revive_or_replay(self):
        cert = self.certificate(); self.batch(cert)
        req = self.revoke(cert['generation'], cert=cert); live.revoke(self.app, req)
        self.assertEqual(self.code(lambda: live.revoke(self.app, req))[1], 'live_request_replay')
        self.app.db.close(); self.app = Relay(self.path, clock=lambda: self.now)
        self.assertEqual(self.code(lambda: self.batch(cert))[1], 'live_grant_revoked')

    def test_frozen_public_vector_matches_canonicals_and_server(self):
        vector = json.loads((Path(__file__).resolve().parents[1] / 'fixtures/protocol/clipboard-live-v1.json').read_text())
        self.assertEqual(live.certificate_bytes(vector['certificate']).hex(), vector['certificateCanonicalHex'])
        self.assertEqual(live.certificate_digest(vector['certificate']).hex(), vector['certificateDigestHex'])
        self.assertEqual(live.event_header(vector['event']).hex(), vector['eventHeaderHex'])
        self.assertEqual(live.request_header(vector['request']).hex(), vector['requestHeaderHex'])
        self.assertEqual(live.revoke_header(vector['revoke']).hex(), vector['revokeHeaderHex'])
        result = live.batch(self.app, vector['request'])
        self.assertEqual(result['accepted'], vector['event']['event'])
        self.assertTrue(live.revoke(self.app, vector['revoke'])['revoked'])

    def test_bad_request_signature_cannot_activate_newer_grant(self):
        first = self.certificate(); self.batch(first)
        other = self.certificate(issued=self.now + 1, generation=str(uuid.uuid4()))
        req = self.batch_request(other); req['signature'] = b64(bytes(64))
        self.assertEqual(self.code(lambda: live.batch(self.app, req))[0], 401)
        self.assertEqual(self.batch(first)['head'], 0)

    def test_certificate_epoch_parent_key_and_permission_checked(self):
        cert = self.certificate(); req = self.batch_request(cert)
        req['epoch'] = 1
        self.assertEqual(self.code(lambda: live.batch(self.app, req))[0], 403)
        wrong = self.certificate(seed=self.fixture['senderSeed'])
        self.assertEqual(self.code(lambda: self.batch(wrong))[1], 'live_member_key')
        state = copy.deepcopy(self.fixture['paired'])
        next(m for m in state['members'] if m['device'] == self.recipient)['permissions'] = 1
        self.app.db.execute('UPDATE groups SET state=? WHERE id=?', (encoded(state), self.group))
        self.assertEqual(self.code(lambda: self.batch(cert))[1], 'live_epoch_or_permission')

    def test_revocation_unknown_generation_blocks_first_registration_and_delegate_cannot_revoke(self):
        cert = self.certificate()
        wrong = self.revoke(cert['generation'], seed=self.fixture['senderSeed'], cert=cert)
        self.assertEqual(self.code(lambda: live.revoke(self.app, wrong))[0], 401)
        req = self.revoke(cert['generation'], cert=cert)
        self.assertTrue(live.revoke(self.app, req)['revoked'])
        self.assertEqual(self.code(lambda: self.batch(cert))[1], 'live_grant_revoked')

    def test_new_generation_revokes_old_and_revoking_old_does_not_revoke_new(self):
        a = self.certificate(); self.batch(a)
        b = self.certificate(issued=self.now + 1, generation=str(uuid.uuid4()))
        self.batch(b)
        self.assertEqual(self.code(lambda: self.batch(a))[1], 'live_grant_stale')
        live.revoke(self.app, self.revoke(a['generation'], cert=a))
        self.assertEqual(self.batch(b)['head'], 0)
        live.revoke(self.app, self.revoke(b['generation'], cert=b))
        self.assertEqual(self.code(lambda: self.batch(a))[1], 'live_grant_revoked')
        self.assertEqual(self.code(lambda: self.batch(b))[1], 'live_grant_revoked')

    def test_revoking_newer_does_not_resurrect_an_older_unrevoked_certificate(self):
        a = self.certificate(); self.batch(a)
        b = self.certificate(issued=self.now + 1, generation=str(uuid.uuid4()))
        self.batch(b); live.revoke(self.app, self.revoke(b['generation'], cert=b))
        self.assertEqual(self.code(lambda: self.batch(a))[1], 'live_grant_stale')

    def test_same_issued_different_cert_cannot_flap_generations(self):
        a = self.certificate(); self.batch(a)
        b = self.certificate(generation=str(uuid.uuid4()))
        self.assertEqual(self.code(lambda: self.batch(b))[1], 'live_grant_conflict')

    def test_legacy_mirror_never_consumes_queue_or_changes_old_replay_and_ack(self):
        self.app.push(self.group, self.message)
        before = {t: self.app.db.execute('SELECT * FROM ' + t).fetchall() for t in ('messages', 'recipients', 'receipts', 'windows')}
        response = self.batch()
        self.assertEqual(response['items'][0]['kind'], 'legacy')
        self.assertEqual(strict_json(base64.b64decode(response['items'][0]['wire'])), self.message)
        self.assertEqual(before, {t: self.app.db.execute('SELECT * FROM ' + t).fetchall() for t in before})
        self.app.rpc(self.group, self.request(3, {'events': [self.message['event']]}))
        self.assertEqual(self.app.db.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
        self.assertEqual(len(self.batch()['items']), 1)

    def test_optional_mirror_failure_never_rolls_back_old_push_and_retry_repairs(self):
        with patch('clipboard_live._append', side_effect=RuntimeError('synthetic mirror failure')):
            self.assertTrue(self.app.push(self.group, self.message)['accepted'])
        self.assertEqual(self.app.db.execute('SELECT count(*) FROM messages').fetchone()[0], 1)
        self.assertEqual(self.app.db.execute('SELECT count(*) FROM clipboard_live_events').fetchone()[0], 0)
        self.app.push(self.group, self.message)
        self.assertEqual(len(self.batch()['items']), 1)

    def test_same_event_compatibility_forward_has_one_feed_entry(self):
        cert = self.certificate(parent=self.message['sender'], seed=self.fixture['senderSeed'])
        event = self.event(cert, event=self.message['event'])
        self.batch(cert, event)
        self.app.push(self.group, self.message)
        self.assertEqual(len(self.batch(cert)['items']), 1)
        self.assertEqual(self.app.db.execute('SELECT count(*) FROM messages').fetchone()[0], 1)

    def test_legacy_then_live_same_event_also_has_one_feed_entry(self):
        self.app.push(self.group, self.message)
        cert = self.certificate(parent=self.message['sender'], seed=self.fixture['senderSeed'])
        self.batch(cert, self.event(cert, event=self.message['event']))
        self.assertEqual(len(self.batch(cert)['items']), 1)

    def test_65_learning_events_plus_clipboard_never_change_original_windows(self):
        for seq in range(1, 130):
            self.app.push(self.group, self.legacy(event=str(uuid.uuid4()), sequence=seq, domain=1))
        self.app.push(self.group, self.legacy(event=str(uuid.uuid4()), sequence=130))
        before = self.app.db.execute('SELECT * FROM windows').fetchall()
        cert = self.certificate(); self.batch(cert, self.event(cert))
        self.assertEqual(len(self.batch(cert)['items']), 2)
        self.assertEqual(before, self.app.db.execute('SELECT * FROM windows').fetchall())
        self.assertEqual(self.app.db.execute('SELECT count(*) FROM messages').fetchone()[0], 130)

    def test_head_persists_after_ttl_expiry_and_maintenance_accepts_old_and_new_schemas(self):
        cert = self.certificate(); self.batch(cert, self.event(cert))
        self.now += 601
        self.assertIsInstance(expire_existing(self.path, self.now), dict)
        result = self.batch(cert, after=1)
        self.assertEqual((result['head'], result['next'], result['items']), (1, 1, []))
        for table in live.TABLES:
            self.app.db.execute('DROP TABLE ' + table)
        self.assertIsInstance(expire_existing(self.path, self.now), dict)
        # A source rollback lacking optional tables still uses old expiry safely.

    def test_expired_feed_wire_is_skipped_and_cursor_advances_without_any_cleanup(self):
        cert = self.certificate(); old = self.event(cert)
        self.batch(cert, old)
        self.now += 601
        fresh = self.event(cert); self.batch(cert, fresh)
        # Model a delayed/absent maintenance operation, including batch's normal
        # relay transaction cleanup: expired rows still physically exist.
        self.app.db.execute('UPDATE clipboard_live_events SET expires=? WHERE cursor=1', (self.now - 1,))
        self.app.db.execute('UPDATE clipboard_live_events SET expires=? WHERE cursor=2', (self.now + 600,))
        wire = encoded(old)
        self.app.db.execute('INSERT OR IGNORE INTO clipboard_live_events VALUES(?,?,?,?,?,?,?,?)',
                            (self.group, 1, old['sender'], old['event'], '2', 'live', self.now - 1, wire))
        with patch.object(self.app, 'clean', return_value=None):
            result = self.batch(cert)
        self.assertEqual([item['cursor'] for item in result['items']], [2])
        self.assertEqual((result['next'], result['head']), (2, 2))

    def test_departed_or_mobile_inactive_requester_cannot_pull(self):
        cert = self.certificate()
        self.app.rpc(self.group, self.request(14))
        self.assertEqual(self.code(lambda: self.batch(cert)), (410, 'device_removed'))

    def test_response_excludes_removed_sender_without_stalling_cursor(self):
        self.app.push(self.group, self.message)
        self.app.db.execute('INSERT INTO departed_devices VALUES(?,?,?)', (self.group, self.message['sender'], 'left'))
        result = self.batch()
        self.assertEqual((result['head'], result['next'], result['items']), (1, 1, []))

    def test_bounds_response_cap_page_resume_and_large_text(self):
        cert = self.certificate()
        for i in range(12):
            self.batch(cert, self.event(cert, 'x' * 65536), after=i)
        result = self.batch(cert)
        self.assertLessEqual(len(encoded(result)), live.MAX_RESPONSE)
        self.assertGreater(len(result['items']), 0)
        self.assertLess(len(result['items']), 12)
        tail = self.batch(cert, after=result['next'])
        self.assertEqual(len(result['items']) + len(tail['items']), 12)
        self.assertEqual(tail['next'], tail['head'])
        self.assertEqual(self.code(lambda: self.batch(cert, after=13))[1], 'live_cursor_ahead')
        self.assertEqual(self.code(lambda: self.batch(cert, limit=33))[0], 400)

    def test_wsgi_status_no_body_and_routes_are_separate(self):
        status = []
        env = {'REQUEST_METHOD': 'GET', 'PATH_INFO': '/clipboard-live/v1/status', 'CONTENT_LENGTH': '0', 'wsgi.input': io.BytesIO(), 'REMOTE_ADDR': '127.0.0.1'}
        result = strict_json(b''.join(self.app(env, lambda value, _: status.append(value))))
        self.assertEqual(status, ['200 OK'])
        self.assertEqual(result, live.capabilities())
        self.assertEqual(self.wsgi('POST', '/clipboard-live/v1/batch', self.batch_request())[0], 200)

    def test_signature_fields_are_bound_and_dont_leak_body_in_wsgi_errors(self):
        cert = self.certificate(); req = self.batch_request(cert, self.event(cert, 'synthetic-private-marker'))
        req['body'] = b64(encoded({'after': 0, 'limit': 1, 'publish': None}))
        status, result = self.wsgi('POST', '/clipboard-live/v1/batch', req)
        self.assertEqual(status, 401)
        self.assertNotIn('synthetic-private-marker', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
