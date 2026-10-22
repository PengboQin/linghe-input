import base64
import copy
import hashlib
import io
import json
import sqlite3
from pathlib import Path
import tempfile
import unittest
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from activity_archive.service import ArchiveError, MemoryAuthority, encode, decode, request_canonical
from cloud_learning.service import LearningStore, LearningApplication, canonical, ALGORITHM, CHARSET_SHA256
from cloud_learning.authority import LearningMembershipAuthority


def uid(): return str(uuid.uuid4()).upper()


class LearningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='learning-synthetic-')
        self.now = 1792600000
        self.keys = {uid(): Ed25519PrivateKey.generate() for _ in range(3)}
        self.a, self.b, self.c = self.keys
        self.group, self.other, self.install, self.install_b = uid(), uid(), uid(), uid()
        self.authority = MemoryAuthority()
        self.members = {k: (v.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3) for k, v in self.keys.items() if k != self.c}
        self.authority.put(self.group, self.members)
        self.authority.put(self.other, {self.c: (self.keys[self.c].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3)})
        self.store = LearningStore(Path(self.temp.name) / 'learning.sqlite', clock=lambda: self.now)
        self.app = LearningApplication(self.store, self.authority, clock=lambda: self.now)
        self.seq = 0

    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def envelope(self, op, body, actor=None, group=None, nonce=None):
        actor, group = actor or self.a, group or self.group
        raw = encode(body)
        e = {'version': 1, 'group': group, 'sender': actor, 'nonce': nonce or uid(), 'issuedAt': self.now, 'operation': op, 'body': base64.b64encode(raw).decode()}
        e['signature'] = base64.b64encode(self.keys[actor].sign(canonical(e, raw))).decode()
        return e

    def call(self, op, body, **kwargs):
        return self.app.dispatch(encode(self.envelope(op, body, **kwargs)))['result']

    def enable(self, actor=None, group=None, install=None):
        actor, group = actor or self.a, group or self.group
        status = self.call(1, {}, actor=actor, group=group)
        if not status['enabled']:
            self.call(2, {'expected_version': status['policy_version'], 'enabled': True}, actor=actor, group=group)
        status = self.call(1, {}, actor=actor, group=group)
        cv = status['consent']['version'] if status['consent'] else 0
        return self.call(3, {'expected_version': cv, 'enabled': True, 'installation_id': install or self.install}, actor=actor, group=group)

    def event(self, kind='confirm', **extra):
        self.seq += 1
        return {'event_id': uid(), 'device_seq': self.seq, 'kind': kind, 'reading': 'dui', 'text': '对', 'layout': 't9', 'term_generation': 0, 'observed_at': self.now} | extra

    def ingest(self, *events, actor=None, group=None, install=None, generation=1, consent=1):
        return self.call(4, {'generation': generation, 'consent_version': consent, 'installation_id': install or self.install, 'events': list(events)}, actor=actor, group=group)

    def tick(self, **kwargs): return self.store.worker_tick(self.authority, force=True, **kwargs)
    def pull(self, version=0, **kwargs): return self.call(5, {'generation': 1, 'from_version': version} | kwargs)

    def error(self, code, op, body, **kwargs):
        with self.assertRaises(ArchiveError) as e: self.call(op, body, **kwargs)
        self.assertEqual(e.exception.code, code)

    def test_defaults_and_independent_device_consent(self):
        status = self.call(1, {})
        self.assertFalse(status['enabled']); self.assertIsNone(status['consent'])
        self.enable()
        self.error('learning_consent_disabled', 5, {'generation': 1, 'from_version': 0}, actor=self.b)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='events'").fetchone()[0], 0)

    def test_idempotent_retry_and_no_change_no_version(self):
        self.enable(); event = self.event()
        self.assertEqual(self.ingest(event)['received_device_seq'], 1)
        self.assertEqual(self.ingest(event)['accepted_event_ids'], [event['event_id']])
        self.assertEqual(self.tick()['groups_published'], 1)
        model = self.pull()
        self.assertEqual(model['upserts'][0]['weight'], 1000)
        self.assertEqual(model['watermarks'][0]['device_seq'], 1)
        self.assertEqual(self.tick()['groups_published'], 0)
        self.assertEqual(self.pull(1)['to_version'], 1)
        expected = hashlib.sha256(encode({'generation': 1, 'algorithm_version': ALGORITHM, 'upserts': model['upserts'], 'watermarks': model['watermarks'], 'producer_watermarks': []})).hexdigest()
        self.assertEqual(model['model_sha256'], expected)

    def test_conflicting_event_and_sequence_gap_rollback(self):
        self.enable(); event = self.event(); self.ingest(event)
        conflict = dict(event, text='队')
        self.error('event_conflict', 4, {'generation': 1, 'consent_version': 1, 'installation_id': self.install, 'events': [conflict]})
        future = self.event(device_seq=3)
        self.error('device_sequence_gap', 4, {'generation': 1, 'consent_version': 1, 'installation_id': self.install, 'events': [future]})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_events').fetchone()[0], 1)

    def test_reset_and_late_event_do_not_poison_queue(self):
        self.enable(); self.ingest(self.event()); self.tick()
        reset = self.event('reset')
        self.assertEqual(self.ingest(reset)['term_generations'][0]['term_generation'], 1)
        late, current = self.event(), self.event(term_generation=1)
        result = self.ingest(late, current)
        self.assertEqual(result['rejected_event_ids'], [{'event_id': late['event_id'], 'reason': 'term_generation_stale'}])
        self.assertEqual(result['received_device_seq'], 4)
        self.tick(); model = self.pull(1)
        self.assertEqual(model['upserts'][0]['weight'], 1000)
        self.assertEqual(model['upserts'][0]['term_generation'], 1)
        self.assertEqual(model['watermarks'][0]['device_seq'], 4)
        self.assertEqual(self.ingest(late)['rejected_event_ids'], result['rejected_event_ids'])
        self.assertEqual(self.ingest(reset)['term_generations'][0]['term_generation'], 1)

    def test_remove_empty_term_publishes_tombstone_then_restore(self):
        self.enable(); self.ingest(self.event('remove')); self.tick()
        self.assertEqual(self.pull()['tombstones'][0]['term_generation'], 1)
        late = self.event(term_generation=1)
        self.assertEqual(self.ingest(late)['rejected_event_ids'][0]['reason'], 'term_removed')
        self.ingest(self.event('restore', term_generation=1), self.event(term_generation=2)); self.tick()
        model = self.pull()
        self.assertEqual(model['upserts'][0]['term_generation'], 2)
        self.assertEqual(model['tombstones'], [])

    def test_controls_not_projected_before_worker_watermark(self):
        self.enable(); self.ingest(self.event(), self.event('pin'))
        self.tick(event_limit=1)
        first = self.pull()
        self.assertFalse(first['upserts'][0]['pinned'])
        self.assertEqual(first['watermarks'][0]['device_seq'], 1)
        self.tick(event_limit=1)
        self.assertTrue(self.pull(1)['upserts'][0]['pinned'])

    def test_cross_device_merge_and_tenant_isolation(self):
        self.enable(); self.enable(actor=self.b, install=self.install_b); self.enable(actor=self.c, group=self.other)
        self.ingest(self.event())
        eb = self.event(device_seq=1, count=2)
        self.ingest(eb, actor=self.b, install=self.install_b)
        ec = self.event(device_seq=1, text='队')
        self.ingest(ec, actor=self.c, group=self.other)
        self.tick()
        model = self.pull()
        self.assertEqual(len(model['upserts']), 1); self.assertEqual(model['upserts'][0]['weight'], 3000)
        self.assertEqual({x['device_id'] for x in model['watermarks']}, {self.a, self.b})

    def test_revoke_removes_contribution_and_pin(self):
        self.enable(); self.ingest(self.event(), self.event('pin')); self.tick()
        self.authority.put(self.group, {self.b: self.members[self.b]}, revision=2)
        self.tick()
        self.enable(actor=self.b, install=self.install_b)
        model = self.call(5, {'generation': 1, 'from_version': 1}, actor=self.b)
        self.assertEqual(model['upserts'][0]['weight'], 0)
        self.assertFalse(model['upserts'][0]['pinned'])
        self.assertEqual(model['watermarks'], [])
        self.error('member', 1, {})

    def test_signing_key_rotation_drops_old_contribution_and_requires_optin(self):
        self.enable(); self.ingest(self.event()); self.tick()
        replacement = Ed25519PrivateKey.generate(); self.keys[self.a] = replacement
        self.members[self.a] = (replacement.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3)
        self.authority.put(self.group, self.members, revision=2)
        self.assertFalse(self.call(1, {})['consent']['enabled'])
        self.error('learning_consent_disabled', 5, {'generation': 1, 'from_version': 0})
        self.tick(); self.enable()
        self.assertEqual(self.pull()['upserts'][0]['weight'], 0)

    def test_group_off_on_rotates_generation_preserves_event_log(self):
        self.enable(); event = self.event(); self.ingest(event); self.tick()
        self.call(2, {'expected_version': 1, 'enabled': False})
        self.call(2, {'expected_version': 2, 'enabled': True})
        status = self.call(1, {})
        self.assertEqual(status['generation'], 3); self.assertFalse(status['consent']['enabled'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_events').fetchone()[0], 1)
        self.assertEqual(status['model_version'], 0)

    def test_scheduler_interval_and_hourly_decay(self):
        self.enable(); self.ingest(self.event())
        self.assertEqual(self.store.worker_tick(self.authority)['groups_published'], 1)
        self.now += 10
        self.assertEqual(self.store.worker_tick(self.authority)['groups_checked'], 0)
        self.now += 600
        self.assertEqual(self.store.worker_tick(self.authority)['groups_published'], 0)
        self.now += 3600
        self.assertEqual(self.store.worker_tick(self.authority)['groups_published'], 1)
        self.assertLess(self.pull()['upserts'][0]['weight'], 1000)

    def test_future_clock_no_boost_and_older_events_are_discounted(self):
        self.enable(); self.ingest(self.event(observed_at=self.now + 86400)); self.tick()
        self.assertEqual(self.pull()['upserts'][0]['weight'], 1000)
        self.ingest(self.event(reading='hao', text='好', observed_at=self.now - 14 * 86400)); self.tick()
        good = next(x for x in self.pull()['upserts'] if x['text'] == '好')
        self.assertEqual(good['weight'], 500)

    def test_simplified_charset_and_no_clipboard_or_raw_key_events(self):
        self.enable()
        for text in ['體', '𨈖', '😀']:
            with self.subTest(text=text), self.assertRaises(ArchiveError): self.ingest(self.event(device_seq=1, text=text))
        for kind in ['clipboard_observed', 'paste_action', 'key']:
            with self.subTest(kind=kind), self.assertRaises(ArchiveError): self.ingest(self.event(kind, device_seq=1))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_events').fetchone()[0], 0)
        self.assertEqual(self.app.capabilities()['charset_sha256'], CHARSET_SHA256)

    def test_signature_domain_replay_and_current_membership(self):
        envelope = self.envelope(1, {})
        self.app.dispatch(encode(envelope))
        with self.assertRaises(ArchiveError) as e: self.app.dispatch(encode(envelope))
        self.assertEqual(e.exception.code, 'nonce_replay')
        raw = base64.b64decode(envelope['body'])
        envelope['nonce'] = uid()
        envelope['signature'] = base64.b64encode(self.keys[self.a].sign(request_canonical(envelope, raw))).decode()
        with self.assertRaises(ArchiveError) as e: self.app.dispatch(encode(envelope))
        self.assertEqual(e.exception.code, 'signature')

    def test_delta_versions_coalesce_and_target_hash(self):
        self.enable(); self.ingest(self.event()); self.tick()
        self.ingest(self.event('pin')); self.tick()
        first = self.pull(limit=1)
        self.assertFalse(first['has_more']); self.assertEqual(first['to_version'], 2)
        second = self.pull(1, limit=1)
        self.assertFalse(second['has_more']); self.assertTrue(second['upserts'][0]['pinned'])
        combined = self.pull()
        self.assertEqual(combined['upserts'], second['upserts'])
        self.assertEqual(combined['model_sha256'], second['model_sha256'])

    def test_wsgi_no_body_error_echo_and_public_capabilities(self):
        status = []
        response = b''.join(self.app({'PATH_INFO': '/v1/learning/capabilities', 'REQUEST_METHOD': 'GET'}, lambda s, h: status.append(s)))
        self.assertEqual(status[-1], '200 OK'); self.assertFalse(decode(response)['clipboard_training'])
        response = b''.join(self.app({'PATH_INFO': '/v1/learning/rpc', 'REQUEST_METHOD': 'POST', 'CONTENT_LENGTH': '12', 'CONTENT_TYPE': 'application/json', 'wsgi.input': io.BytesIO(b'SECRET')}, lambda s, h: status.append(s)))
        self.assertNotIn(b'SECRET', response); self.assertEqual(status[-1], '400 Bad Request')

    def test_same_id_key_reentry_requires_new_consent_signed_history(self):
        from private_input_relay import membership_bytes, membership_canonical
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        b64 = lambda value: base64.b64encode(value).decode()
        members = [{'device': device, 'signingPublic': b64(self.members[device][0]),
                    'exchangePublic': b64(X25519PrivateKey.generate().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)), 'permissions': 3} for device in (self.a, self.b)]
        initial = {'version': 1, 'group': self.group, 'ownerID': self.a, 'ownerPublic': b64(self.members[self.a][0]), 'revision': 1, 'epoch': 1, 'members': [members[0]], 'signature': ''}
        initial['signature'] = b64(self.keys[self.a].sign(membership_canonical(initial)))
        def next_state(previous, current_members):
            state = {k: copy.deepcopy(v) for k, v in previous.items() if k != 'history'}
            state.update(version=2, revision=previous['revision']+1, epoch=previous['revision']+1,
                         issuer=self.a, parent=b64(membership_bytes(previous)[2]), members=current_members,
                         history=previous.get('history', []) + [{k: v for k, v in previous.items() if k != 'history'}])
            state['signature'] = b64(self.keys[self.a].sign(membership_canonical(state)))
            return state
        joined = next_state(initial, members)
        removed = next_state(joined, [members[0]])
        rejoined = next_state(removed, members)
        path = Path(self.temp.name) / 'synthetic-relay.sqlite'
        db = sqlite3.connect(path)
        db.execute('CREATE TABLE groups(id TEXT PRIMARY KEY,root BLOB,revision TEXT,digest BLOB,state BLOB)')
        def save(state):
            group, root, digest = membership_bytes(state)
            db.execute('INSERT OR REPLACE INTO groups VALUES(?,?,?,?,?)', (group, root, str(state['revision']), digest, encode(state))); db.commit()
        save(joined)
        self.authority = LearningMembershipAuthority(path)
        self.app.authority = self.authority
        self.enable(actor=self.b, install=self.install_b)
        self.assertTrue(self.call(1, {}, actor=self.b)['consent']['enabled'])
        # No cloud-learning request or worker ran while B was absent.
        save(rejoined)
        self.assertFalse(self.call(1, {}, actor=self.b)['consent']['enabled'])
        self.error('learning_consent_disabled', 5, {'generation': 1, 'from_version': 0}, actor=self.b)
        self.enable(actor=self.b, install=self.install_b)
        self.assertTrue(self.call(1, {}, actor=self.b)['consent']['enabled'])
        self.assertEqual(db.execute('SELECT COUNT(*) FROM sqlite_master WHERE name LIKE "cl_%"').fetchone()[0], 0)
        db.close()

    def test_actual_swift_generated_signature_cross_language(self):
        path = Path(__file__).resolve().parents[1] / 'fixtures/swift-status-request-v1.json'
        vector = json.loads(path.read_text())
        self.assertEqual(vector['fixture_kind'], 'synthetic_only')
        request = vector['request']
        authority = MemoryAuthority()
        authority.put(request['group'], {request['sender']: (base64.b64decode(vector['public_key']), 3)})
        app = LearningApplication(self.store, authority, clock=lambda: request['issuedAt'])
        result = app.dispatch(encode(request))
        self.assertEqual(result['operation'], 1)
        self.assertFalse(result['result']['enabled'])
        self.assertEqual(result['result']['generation'], 0)

    def test_bounded_group_worker_rotates_oldest_first(self):
        self.enable(); self.enable(actor=self.c, group=self.other)
        first = self.store.worker_tick(self.authority, group_limit=1)
        second = self.store.worker_tick(self.authority, group_limit=1)
        self.assertEqual(first['groups_checked'], 1)
        self.assertEqual(second['groups_checked'], 1)
        self.assertEqual(self.store.worker_tick(self.authority, group_limit=1)['groups_checked'], 0)

    def test_pin_and_reset_forget_no_premature_model_rebuild(self):
        self.enable(); self.ingest(self.event('pin')); self.tick()
        self.assertTrue(self.pull()['upserts'][0]['pinned'])
        self.ingest(self.event('reset')); self.tick()
        reset = self.pull(1)
        self.assertEqual(reset['upserts'][0]['term_generation'], 1)
        self.assertFalse(reset['upserts'][0]['pinned'])
        self.assertEqual(reset['upserts'][0]['weight'], 0)
        self.assertEqual(self.tick()['groups_published'], 0)


if __name__ == '__main__': unittest.main()
