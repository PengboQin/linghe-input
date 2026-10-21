import base64
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import unittest
import uuid

SERVER = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SERVER))
from activity_archive.service import ArchiveApplication, ArchiveStore, ArchiveError, MemoryAuthority, RelayMembershipAuthority, encode, decode, request_canonical, iso
from activity_archive.production import LocalArchiveProxy
from activity_archive.metadata import latest_authorized_activity
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = SERVER.parent


def identifier():
    return str(uuid.uuid4()).upper()


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = ROOT / 'build/evidence/activity_archive'
        self.directory.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='synthetic-', dir=self.directory)
        self.path = Path(self.temp.name) / 'activity.sqlite'
        self.now = 1792320000
        self.keys = {identifier(): Ed25519PrivateKey.generate() for _ in range(4)}
        self.a, self.b, self.c, self.d = list(self.keys)
        self.group, self.other_group, self.install = identifier(), identifier(), identifier()
        self.authority = MemoryAuthority()
        self.members = {k: (v.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3 if k == self.a else 1) for k, v in self.keys.items() if k != self.d}
        self.authority.put(self.group, self.members)
        self.authority.put(self.other_group, {self.d: (self.keys[self.d].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3)})
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = ArchiveApplication(self.store, self.authority, clock=lambda: self.now)
        self.n = 0

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def envelope(self, op, body, *, actor=None, group=None, nonce=None, issued=None):
        actor, group = actor or self.a, group or self.group
        raw = encode(body)
        value = {'version': 1, 'group': group, 'sender': actor, 'nonce': nonce or identifier(), 'issuedAt': int(self.now if issued is None else issued), 'operation': op, 'body': base64.b64encode(raw).decode()}
        value['signature'] = base64.b64encode(self.keys[actor].sign(request_canonical(value, raw))).decode()
        return value

    def call(self, op, body, **kwargs):
        return self.app.dispatch(encode(self.envelope(op, body, **kwargs)))['result']

    def assert_error(self, code, op, body, **kwargs):
        with self.assertRaises(ArchiveError) as caught:
            self.call(op, body, **kwargs)
        self.assertEqual(caught.exception.code, code)

    def enable(self, *, actor=None, readers=None, group=None):
        actor, group = actor or self.a, group or self.group
        if not self.call(1, {}, actor=actor, group=group)['enabled']:
            manager = self.a if group == self.group else self.d
            self.call(2, {'expected_version': 0, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 104857600}, actor=manager, group=group)
        return self.call(3, {'expected_version': 0, 'enabled': True, 'providers': ['ime.commit.v1', 'clipboard.observed.v1'], 'readers': readers if readers is not None else [actor]}, actor=actor, group=group)

    def event(self, text='明天下午讨论方案 🦢 e\u0301\n"quoted"', *, actor=None, group=None, seq=None, **extra):
        self.n += 1
        actor, group = actor or self.a, group or self.group
        value = {'schema_version': 1, 'event_id': identifier(), 'device_group': group, 'device_id': actor, 'installation_id': self.install, 'device_seq': self.n if seq is None else seq, 'provider_id': 'ime.commit.v1', 'event_type': 'input_commit', 'observed_at': iso(self.now), 'content': {'text': text}, 'consent_version': 1}
        value.update(extra)
        return value

    def ingest(self, *events, actor=None, group=None, batch=None):
        return self.call(4, {'batch_id': batch or identifier(), 'events': list(events)}, actor=actor, group=group)

    def test_device_inventory_is_current_group_and_reader_scoped(self):
        self.enable(actor=self.b)
        metadata={'platform':'android','brand':'vivo','model':'synthetic-model','serial':'MUST_NOT_LEAK'}
        self.ingest(self.event(actor=self.b,extensions={'org.linghe.device.v1':metadata}),actor=self.b)
        inventory=self.call(1,{})['devices']
        self.assertEqual({d['device_id'] for d in inventory},{self.a,self.b,self.c})
        self.assertIsNone(next(d for d in inventory if d['device_id']==self.b)['metadata'])
        self.call(3,{'expected_version':1,'enabled':True,'providers':['ime.commit.v1'],'readers':[self.a,self.b]},actor=self.b)
        device=next(d for d in self.call(1,{})['devices'] if d['device_id']==self.b)
        self.assertEqual(device['metadata']['model'],'synthetic-model')
        self.assertNotIn('serial',device['metadata'])
        self.authority.put(self.group,{self.a:self.members[self.a],self.c:self.members[self.c]},revision=2)
        self.assertNotIn(self.b,{d['device_id'] for d in self.call(1,{})['devices']})

    def test_unselected_diagnostics_need_distinct_provider_consent(self):
        self.enable()
        detail={'action':'key','key':'4','raw_before':'44','raw_after':'444','committed':False}
        event=self.event('444',provider_id='ime.diagnostic.v1',event_type='source_import',source_kind='ime_diagnostic',commit_confirmation='not_applicable',extensions={'org.linghe.input.v1':detail})
        self.assert_error('provider_not_allowed',4,{'batch_id':identifier(),'events':[event]})
        self.call(3,{'expected_version':1,'enabled':True,'providers':['ime.commit.v1','ime.diagnostic.v1']})
        event['consent_version']=2
        self.ingest(event)
        row=self.store.db.execute('SELECT event_json FROM events WHERE event_id=?',(event['event_id'],)).fetchone()
        self.assertEqual(decode(row[0])['extensions']['org.linghe.input.v1'],detail)

    def test_default_disabled_and_policy_does_not_enable_other_device(self):
        self.assertFalse(self.call(1, {})['enabled'])
        self.assert_error('archive_disabled', 4, {'batch_id': identifier(), 'events': [self.event()]})
        self.enable()
        self.assert_error('consent_disabled', 4, {'batch_id': identifier(), 'events': [self.event(actor=self.b)]}, actor=self.b)
        self.assertIsNone(self.call(1, {}, actor=self.b)['consent'])

    def test_close_then_reopen_requires_new_explicit_device_consent(self):
        self.enable()
        event = self.event()
        self.call(2, {'expected_version': 1, 'enabled': False, 'retention_days': 30, 'max_group_bytes': 104857600})
        closed = self.call(1, {})['consent']
        self.assertFalse(closed['enabled'])
        self.assertEqual(closed['version'], 2)
        self.call(2, {'expected_version': 2, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 104857600})
        self.assert_error('consent_disabled', 4, {'batch_id': identifier(), 'events': [event]})
        self.call(3, {'expected_version': 2, 'enabled': True, 'providers': ['ime.commit.v1']})
        self.assert_error('consent_stale', 4, {'batch_id': identifier(), 'events': [event]})

    def test_tenant_change_watermark_does_not_reveal_other_groups_activity(self):
        self.enable()
        self.enable(actor=self.d, group=self.other_group)
        self.ingest(self.event(actor=self.d, group=self.other_group), actor=self.d, group=self.other_group)
        result = self.ingest(self.event())
        self.assertEqual(result['high_watermark'], 1)

    def delegate_request(self, operation, body, key, *, actor=None, group=None):
        request = self.envelope(operation, body, actor=actor, group=group)
        raw = base64.b64decode(request['body'])
        request['signature'] = base64.b64encode(key.sign(request_canonical(request, raw))).decode()
        return self.app.dispatch(encode(request))['result']

    def test_capture_delegate_can_only_own_status_and_ingest(self):
        self.enable()
        key = Ed25519PrivateKey.generate()
        body = {'expected_consent_version': 1, 'public_key': base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()}
        result = self.call(11, body)
        self.assertEqual(result, {'registered': True, 'consent_version': 1})
        delegate_status = self.delegate_request(1, {}, key)
        self.assertEqual(delegate_status['device'], self.a)
        self.assertNotIn('devices', delegate_status)
        event = self.event()
        accepted = self.delegate_request(4, {'batch_id': identifier(), 'events': [event]}, key)
        self.assertEqual(accepted['accepted_event_ids'], [event['event_id']])
        for operation in [2, 3, 5, 6, 7, 8, 9, 10, 11]:
            with self.subTest(operation=operation):
                with self.assertRaises(ArchiveError) as caught:
                    self.delegate_request(operation, body, key)
                self.assertEqual(caught.exception.code, 'signature')
        with self.assertRaises(ArchiveError):
            self.delegate_request(1, {}, key, actor=self.b)
        with self.assertRaises(ArchiveError):
            self.delegate_request(1, {}, key, actor=self.d, group=self.other_group)

    def test_delegate_registration_requires_active_generation_and_new_consent_revokes(self):
        key = Ed25519PrivateKey.generate()
        body = {'expected_consent_version': 1, 'public_key': base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()}
        self.assert_error('consent_disabled', 11, body)
        self.enable()
        bad = dict(body, expected_consent_version=2)
        self.assert_error('consent_stale', 11, bad)
        self.call(11, body)
        self.call(3, {'expected_version': 1, 'enabled': True, 'providers': ['ime.commit.v1']})
        with self.assertRaises(ArchiveError) as caught:
            self.delegate_request(1, {}, key)
        self.assertEqual(caught.exception.code, 'signature')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM capture_keys').fetchone()[0], 0)

    def test_delegate_bound_to_current_member_signing_fingerprint(self):
        self.enable()
        key = Ed25519PrivateKey.generate()
        self.call(11, {'expected_consent_version': 1, 'public_key': base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()})
        replacement = Ed25519PrivateKey.generate()
        self.members[self.a] = (replacement.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw), 3)
        self.authority.put(self.group, self.members, revision=2)
        with self.assertRaises(ArchiveError) as caught:
            self.delegate_request(1, {}, key)
        self.assertEqual(caught.exception.code, 'signature')

    def test_policy_requires_current_full_member_and_cas(self):
        value = {'expected_version': 0, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 104857600}
        self.assert_error('manage_permission', 2, value, actor=self.b)
        self.call(2, value)
        self.assert_error('policy_conflict', 2, value)
        self.assert_error('fields', 3, {'device_id': self.b, 'expected_version': 0, 'enabled': True, 'providers': ['ime.commit.v1']})

    def test_provider_consent_version_disable_and_group_close_reject_old_queue(self):
        self.enable()
        e = self.event()
        self.call(3, {'expected_version': 1, 'enabled': True, 'providers': ['ime.commit.v1']})
        self.assert_error('consent_stale', 4, {'batch_id': identifier(), 'events': [e]})
        e['consent_version'] = 2
        e['provider_id'] = 'clipboard.observed.v1'
        self.assert_error('provider_not_allowed', 4, {'batch_id': identifier(), 'events': [e]})
        self.call(3, {'expected_version': 2, 'enabled': False, 'providers': ['ime.commit.v1']})
        self.assert_error('consent_disabled', 4, {'batch_id': identifier(), 'events': [e]})
        self.call(2, {'expected_version': 1, 'enabled': False, 'retention_days': 30, 'max_group_bytes': 104857600})
        self.assert_error('archive_disabled', 4, {'batch_id': identifier(), 'events': [e]})

    def test_plaintext_unicode_preserved_without_normalizing(self):
        self.enable()
        e = self.event()
        self.ingest(e)
        result = self.call(5, {})['events'][0]
        self.assertEqual(result['content'], e['content'])
        self.assertEqual(result['observed_at'], e['observed_at'])
        self.assertEqual(len(result['content_hash']), 64)
        self.assertIn('server_received_at', result)
        exported = self.call(8, {})
        lines = [json.loads(line) for line in exported['jsonl'].splitlines()]
        self.assertEqual(lines[1]['event']['content'], e['content'])

    def test_source_context_survives_query_and_export_without_inventing_ios_host(self):
        self.enable()
        originals = []
        for platform, app_id, app_name in [('macos', 'com.example.Editor', '合成编辑器'), ('ios', None, None)]:
            context = {'platform': platform, 'app_identity_status': 'available' if app_id else 'unavailable',
                       'input_method_version': '1.0.0', 'input_method_build': '67',
                       'field_type': 'text', 'return_key': 'send', 'layout': 'nine'}
            if app_id:
                context.update(source_app_id=app_id, source_app_name=app_name)
            event = self.event('合成场景记录', source_app=app_id,
                               extensions={'org.linghe.context.v1': context})
            originals.append(event)
            self.ingest(event)
        queried = {event['event_id']: event for event in self.call(5, {})['events']}
        exported = {line['event']['event_id']: line['event'] for line in
                    map(json.loads, self.call(8, {})['jsonl'].splitlines()) if 'event' in line}
        for event in originals:
            for result in [queried[event['event_id']], exported[event['event_id']]]:
                self.assertEqual(result['source_app'], event['source_app'])
                self.assertEqual(result['extensions'], event['extensions'])
                self.assertEqual(result['content'], event['content'])

    def test_event_identity_and_cross_tenant_isolation(self):
        self.enable()
        self.enable(actor=self.d, group=self.other_group)
        e = self.event()
        self.ingest(e)
        self.assertEqual(self.call(5, {}, actor=self.d, group=self.other_group)['events'], [])
        wrong = self.event(group=self.other_group)
        self.assert_error('event_identity', 4, {'batch_id': identifier(), 'events': [wrong]})
        wrong = self.event(actor=self.b)
        self.assert_error('event_identity', 4, {'batch_id': identifier(), 'events': [wrong]})

    def test_readers_are_explicit_and_manager_cannot_read_other_devices(self):
        self.enable()
        self.enable(actor=self.b)
        self.ingest(self.event(actor=self.b), actor=self.b)
        self.assertEqual(self.call(5, {})['events'], [])
        self.call(3, {'expected_version': 1, 'enabled': True, 'providers': ['ime.commit.v1'], 'readers': [self.a]}, actor=self.b)
        self.assertEqual(len(self.call(5, {})['events']), 1)
        self.assertEqual(self.call(5, {}, actor=self.c)['events'], [])
        self.assert_error('reader_member', 3, {'expected_version': 1, 'enabled': True, 'providers': ['ime.commit.v1'], 'readers': [self.d]})

    def test_acl_retraction_invalidates_cursor_and_removes_visibility(self):
        self.enable(actor=self.b, readers=[self.a])
        self.ingest(self.event(actor=self.b), self.event(actor=self.b), actor=self.b)
        page = self.call(5, {'limit': 1})
        self.assertIsNotNone(page['next_cursor'])
        self.call(3, {'expected_version': 1, 'enabled': True, 'providers': ['ime.commit.v1'], 'readers': [self.b]}, actor=self.b)
        self.assert_error('cursor_stale', 5, {'cursor': page['next_cursor']})
        self.assertEqual(self.call(5, {})['events'], [])

    def test_nonce_signature_domain_clock_and_current_revocation(self):
        request = self.envelope(1, {})
        self.app.dispatch(encode(request))
        with self.assertRaises(ArchiveError) as caught:
            self.app.dispatch(encode(request))
        self.assertEqual(caught.exception.code, 'replay')
        request = self.envelope(1, {})
        request['signature'] = base64.b64encode(bytes(64)).decode()
        with self.assertRaises(ArchiveError) as caught:
            self.app.dispatch(encode(request))
        self.assertEqual(caught.exception.code, 'signature')
        self.assert_error('request_clock', 1, {}, issued=self.now - 301)
        self.members.pop(self.b)
        self.authority.put(self.group, self.members, revision=2)
        self.assert_error('member', 1, {}, actor=self.b)

    def test_duplicate_event_retry_and_conflict_are_atomic(self):
        self.enable()
        e = self.event()
        first = self.ingest(e)
        again = self.ingest(e)
        self.assertEqual(first['accepted_event_ids'], [e['event_id']])
        self.assertEqual(again['duplicate_event_ids'], [e['event_id']])
        bad = copy.deepcopy(e); bad['content']['text'] = 'changed'
        fresh = self.event()
        self.assert_error('event_conflict', 4, {'batch_id': identifier(), 'events': [fresh, bad]})
        self.assertEqual(len(self.call(5, {})['events']), 1)

    def test_seq_gaps_and_late_arrival_ack_ranges(self):
        self.enable()
        e1, e3 = self.event(seq=1), self.event(seq=3)
        first = self.ingest(e1, e3)['received_ranges'][0]
        self.assertEqual(first['ranges'], [[1, 1], [3, 3]])
        self.assertEqual(first['contiguous_through'], 1)
        late = self.ingest(self.event(seq=2))['received_ranges'][0]
        self.assertEqual(late['ranges'], [[2, 2]])
        self.assertEqual(late['contiguous_through'], 3)
        self.assert_error('sequence_conflict', 4, {'batch_id': identifier(), 'events': [self.event(seq=2)]})

    def test_batch_conflict_and_repeated_id_in_batch(self):
        self.enable()
        e, batch = self.event(), identifier()
        self.ingest(e, batch=batch)
        self.assert_error('batch_conflict', 4, {'batch_id': batch, 'events': [self.event()]})
        self.assert_error('batch_event_duplicate', 4, {'batch_id': identifier(), 'events': [e, e]})

    def test_receive_cursor_does_not_lose_old_clock_late_events(self):
        self.enable()
        self.ingest(self.event())
        current = self.call(6, {})['next_cursor']
        late = self.event(observed_at=iso(self.now - 5000))
        self.ingest(late)
        changes = self.call(6, {'cursor': current})['changes']
        self.assertEqual([c['event_id'] for c in changes], [late['event_id']])

    def test_snapshot_fixed_high_watermark_and_incremental_successor(self):
        self.enable()
        first, second = self.event(), self.event()
        self.ingest(first, second)
        snap = self.call(7, {'limit': 1})
        third = self.event()
        self.ingest(third)
        next_page = self.call(7, {'cursor': snap['next_cursor'], 'limit': 1})
        self.assertEqual([e['event_id'] for e in next_page['events']], [second['event_id']])
        self.assertIsNone(next_page['next_cursor'])
        changes = self.call(6, {'cursor': snap['changes_cursor']})
        self.assertEqual([e['event_id'] for e in changes['changes']], [third['event_id']])

    def test_cursor_cross_reader_group_tamper_and_expiration(self):
        self.enable()
        self.ingest(self.event(), self.event())
        token = self.call(5, {'limit': 1})['next_cursor']
        self.assert_error('cursor_scope', 5, {'cursor': token}, actor=self.b)
        self.assert_error('cursor_scope', 5, {'cursor': token}, actor=self.d, group=self.other_group)
        mutated = token[:20] + ('A' if token[20] != 'A' else 'B') + token[21:]
        self.assert_error('cursor', 5, {'cursor': mutated})
        self.now += 86401
        self.assert_error('cursor_expired', 5, {'cursor': token})

    def test_membership_change_stales_cursor_even_without_policy_change(self):
        self.enable()
        self.ingest(self.event(), self.event())
        cursor = self.call(5, {'limit': 1})['next_cursor']
        self.members.pop(self.b)
        self.authority.put(self.group, self.members, revision=2)
        self.assert_error('cursor_stale', 5, {'cursor': cursor})

    def test_erase_clears_fts_and_incremental_content_and_blocks_resurrection(self):
        self.enable()
        e = self.event('EraseUniqueNeedle秘密')
        self.ingest(e)
        cursor = self.call(6, {})['next_cursor']
        result = self.call(9, {'event_ids': [e['event_id']]})
        self.assertEqual(result['erased_event_ids'], [e['event_id']])
        self.assertEqual(result['storage_cleanup'], 'checkpointed')
        self.assertNotIn(b'EraseUniqueNeedle', self.path.read_bytes())
        self.assertEqual(self.call(5, {})['events'], [])
        if self.store.fts:
            self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM event_search').fetchone()[0], 0)
        changes = self.call(6, {'cursor': cursor})['changes']
        self.assertEqual(changes[0]['kind'], 'erase')
        self.assertEqual(changes[0]['erase_reason'], 'user_erase')
        self.assertNotIn('event', changes[0])
        self.assertNotIn('EraseUniqueNeedle', str(self.call(6, {})))
        self.assert_error('event_erased', 4, {'batch_id': identifier(), 'events': [e]})
        alternate = copy.deepcopy(e); alternate['event_id'] = identifier()
        self.assert_error('event_erased', 4, {'batch_id': identifier(), 'events': [alternate]})
        self.call(9, {'event_ids': [e['event_id']]})

    def test_manager_cannot_erase_others_even_with_read_permission(self):
        self.enable(actor=self.b, readers=[self.a])
        event = self.event(actor=self.b)
        self.ingest(event, actor=self.b)
        self.assert_error('erase_owner', 9, {'event_ids': [event['event_id']]})
        self.assertEqual(len(self.call(5, {})['events']), 1)

    def test_privacy_delete_cascades_raw_revision_events(self):
        self.enable()
        e = self.event('old', input_session='s', editor_epoch='e')
        self.ingest(e)
        revision = self.event('new', event_type='text_revise', input_session='s', editor_epoch='e', edit_op={'kind': 'replace', 'target_event_id': e['event_id']})
        self.ingest(revision)
        erased = self.call(9, {'event_ids': [e['event_id']]})
        self.assertEqual(set(erased['erased_event_ids']), {e['event_id'], revision['event_id']})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM event_revisions').fetchone()[0], 0)
        self.assert_error('event_erased', 4, {'batch_id': identifier(), 'events': [revision]})

    def test_backup_restore_replays_newest_erasure_ledger_before_serving(self):
        self.enable()
        e = self.event('must not resurrect')
        self.ingest(e)
        snapshot = Path(self.temp.name) / 'snapshot.sqlite'
        self.store.backup(snapshot)
        self.call(9, {'event_ids': [e['event_id']]})
        self.store.close()
        for suffix in ['', '-wal', '-shm']:
            Path(str(self.path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(snapshot, self.path)
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = ArchiveApplication(self.store, self.authority, clock=lambda: self.now)
        self.assertEqual(self.call(5, {})['events'], [])
        self.assert_error('event_erased', 4, {'batch_id': identifier(), 'events': [e]})

    def test_retention_expires_content_and_prevents_reupload(self):
        self.enable()
        e = self.event()
        self.ingest(e)
        self.now += 31 * 86400
        self.assertEqual(self.call(5, {})['events'], [])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM deletion_tombstones').fetchone()[0], 1)
        self.assertEqual(self.store.erase_reason(self.group, e['event_id']), 'retention_expire')
        changes = self.call(6, {})['changes']
        self.assertTrue(all(change['erase_reason'] == 'retention_expire' for change in changes))
        e['observed_at'] = iso(self.now)
        self.assert_error('event_erased', 4, {'batch_id': identifier(), 'events': [e]})

    def reopen_store(self):
        self.store.close()
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = ArchiveApplication(self.store, self.authority, clock=lambda: self.now)

    def test_active_erase_upgrades_expired_tombstone_and_emits_once(self):
        self.enable()
        event = self.event('synthetic expiry then privacy erase')
        self.ingest(event)
        self.now += 31 * 86400
        self.call(5, {})
        cursor = self.call(6, {})['next_cursor']
        high = self.store.high(self.group)
        self.assert_error('erase_owner', 9, {'event_ids': [event['event_id']]}, actor=self.b)
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'retention_expire')
        self.call(9, {'event_ids': [event['event_id']]})
        changes = self.call(6, {'cursor': cursor})['changes']
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]['kind'], 'erase')
        self.assertEqual(changes[0]['erase_reason'], 'user_erase')
        self.assertEqual(self.store.high(self.group), high + 1)
        self.call(9, {'event_ids': [event['event_id']]})
        self.assertEqual(self.store.high(self.group), high + 1)
        entries = [decode(line) for line in self.store.ledger_path.read_bytes().splitlines()]
        self.assertEqual([entry['erase_reason'] for entry in entries], ['retention_expire', 'user_erase'])

    def test_expired_revision_cascade_survives_restore_before_event_creation(self):
        self.enable()
        snapshot = Path(self.temp.name) / 'empty-snapshot.sqlite'
        self.store.backup(snapshot)
        base = self.event('synthetic revision base', input_session='s', editor_epoch='e')
        self.ingest(base)
        revision = self.event('synthetic revision content', event_type='text_revise', input_session='s', editor_epoch='e', edit_op={'kind': 'replace', 'target_event_id': base['event_id']})
        self.ingest(revision)
        self.now += 31 * 86400
        self.call(5, {})
        self.store.close()
        for suffix in ['', '-wal', '-shm']:
            Path(str(self.path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(snapshot, self.path)
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = ArchiveApplication(self.store, self.authority, clock=lambda: self.now)
        self.assertEqual(self.store.erase_reason(self.group, base['event_id']), 'retention_expire')
        self.assertEqual(self.store.erase_reason(self.group, revision['event_id']), 'retention_expire')
        cursor = self.call(6, {})['next_cursor']
        result = self.call(9, {'event_ids': [base['event_id']]})
        self.assertEqual(set(result['erased_event_ids']), {base['event_id'], revision['event_id']})
        changes = self.call(6, {'cursor': cursor})['changes']
        self.assertEqual({change['event_id'] for change in changes}, {base['event_id'], revision['event_id']})
        self.assertTrue(all(change['erase_reason'] == 'user_erase' for change in changes))

    def test_legacy_ledger_and_tombstones_are_unknown_and_schema_is_additive(self):
        self.enable()
        event = self.event('synthetic legacy ledger')
        self.ingest(event)
        legacy = {'group_id': self.group, 'event_id': event['event_id'], 'device_id': self.a, 'installation_id': self.install, 'device_seq': event['device_seq']}
        self.store.ledger_path.write_bytes(encode(legacy) + b'\n')
        self.reopen_store()
        self.assertEqual(self.call(5, {})['events'], [])
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'unknown')
        self.assertTrue(all(change['erase_reason'] == 'unknown' for change in self.call(6, {})['changes']))
        self.store.db.execute('DROP TABLE erasure_reasons')
        self.store.db.execute('DROP TABLE erasure_revision_links')
        self.reopen_store()
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'unknown')
        self.assertEqual(len(self.store.db.execute('PRAGMA table_info(deletion_tombstones)').fetchall()), 6)
        self.assertEqual(len(self.store.db.execute('PRAGMA table_info(change_log)').fetchall()), 6)
        self.call(9, {'event_ids': [event['event_id']]})
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'user_erase')

    def test_restore_keeps_retention_reason_and_never_downgrades_user_erase(self):
        self.enable()
        event = self.event('synthetic restore retention')
        self.ingest(event)
        snapshot = Path(self.temp.name) / 'live-snapshot.sqlite'
        self.store.backup(snapshot)
        self.now += 31 * 86400
        self.call(5, {})
        self.store.close()
        for suffix in ['', '-wal', '-shm']:
            Path(str(self.path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(snapshot, self.path)
        self.store = ArchiveStore(self.path, clock=lambda: self.now)
        self.app = ArchiveApplication(self.store, self.authority, clock=lambda: self.now)
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'retention_expire')
        self.call(9, {'event_ids': [event['event_id']]})
        # An older/duplicated retention entry after the upgrade must not weaken it.
        first = self.store.ledger_path.read_bytes().splitlines()[0]
        with self.store.ledger_path.open('ab') as stream:
            stream.write(first + b'\n')
        high = self.store.high(self.group)
        self.reopen_store()
        self.assertEqual(self.store.erase_reason(self.group, event['event_id']), 'user_erase')
        self.assertEqual(self.store.high(self.group), high)

    def test_unknown_fragments_never_become_final_document(self):
        self.enable()
        self.ingest(self.event('（）', input_session='s', editor_epoch='e'), self.event('明天', input_session='s', editor_epoch='e'))
        paragraphs = self.call(10, {})['paragraphs']
        self.assertEqual([p['text'] for p in paragraphs], ['（）', '明天'])
        self.assertTrue(all(not p['complete'] for p in paragraphs))
        self.assertTrue(all(p['view_kind'] == 'fragment_sequence' for p in paragraphs))

    def test_explicit_same_epoch_anchor_can_form_traceable_fragment_view(self):
        self.enable()
        e = self.event('我们', input_session='s', editor_epoch='e')
        next_event = self.event('明天讨论', input_session='s', editor_epoch='e', edit_op={'kind': 'insert', 'anchor': {'kind': 'after_event', 'event_id': e['event_id']}})
        third = self.event('新输入框', input_session='s', editor_epoch='different', edit_op={'kind': 'insert', 'anchor': {'kind': 'after_event', 'event_id': next_event['event_id']}})
        self.ingest(e, next_event, third)
        views = self.call(10, {})['paragraphs']
        self.assertEqual(views[0]['text'], '我们明天讨论')
        self.assertEqual(views[0]['source_event_ids'], [e['event_id'], next_event['event_id']])
        self.assertEqual(len(views), 2)
        self.assertFalse(views[0]['complete'])

    def test_clipboard_same_text_is_not_paste_or_global_deduplication(self):
        self.enable()
        events = [self.event('same'), self.event('same', event_type='clipboard_observed', provider_id='clipboard.observed.v1'), self.event('same')]
        self.ingest(*events)
        result = self.call(5, {})['events']
        self.assertEqual(len(result), 3)
        self.assertNotIn('paste_action', [e['event_type'] for e in result])

    def test_clipboard_cannot_be_promoted_to_ime_paragraph_by_anchor(self):
        self.enable()
        clipboard = self.event('复制内容', event_type='clipboard_observed', provider_id='clipboard.observed.v1', input_session='s', editor_epoch='e')
        typed = self.event('真实输入', input_session='s', editor_epoch='e', edit_op={'kind': 'insert', 'anchor': {'kind': 'after_event', 'event_id': clipboard['event_id']}})
        self.ingest(clipboard, typed)
        views = self.call(10, {})['paragraphs']
        self.assertEqual([p['text'] for p in views], ['复制内容', '真实输入'])

    def test_protocol_rejects_oversize_and_duplicate_keys_without_body_leak(self):
        self.enable()
        too_big = self.event('x' * 262144)
        self.assert_error('event_size', 4, {'batch_id': identifier(), 'events': [too_big]})
        with self.assertRaises(ArchiveError) as caught:
            self.app.dispatch(b'{"version":1,"version":2}')
        self.assertEqual(caught.exception.code, 'duplicate_field')
        with self.assertRaises(ArchiveError) as caught:
            self.app.dispatch(b' ' * 1048577)
        self.assertEqual(caught.exception.status, 413)
        self.assert_error('gap_text', 4, {'batch_id': identifier(), 'events': [self.event('private', event_type='coverage_gap')]})
        audit = [dict(r) for r in self.store.db.execute('SELECT * FROM admin_audit')]
        self.assertNotIn('private', str(audit))

    def test_event_metadata_limits_types_unknown_fields_and_clock(self):
        self.enable()
        for extra in [{'device_seq': True}, {'observed_at': 'bad'}, {'observed_at': iso(self.now + 90000)}, {'content': {'text': 2}}, {'unexpected': 'x'}, {'extensions': []}]:
            with self.subTest(extra=extra):
                with self.assertRaises(ArchiveError):
                    self.ingest(self.event(**extra))
        expired = self.event(observed_at=iso(self.now - 31 * 86400))
        self.assert_error('event_expired', 4, {'batch_id': identifier(), 'events': [expired]})

    def test_query_filters_do_not_override_acl_and_cursor_filters_are_fixed(self):
        self.enable()
        first = self.event(event_type='clipboard_observed', provider_id='clipboard.observed.v1')
        self.ingest(first, self.event(), self.event())
        page = self.call(5, {'limit': 1, 'filters': {'event_type': 'input_commit'}})
        self.assertEqual(len(page['events']), 1)
        self.assert_error('cursor_filters', 5, {'cursor': page['next_cursor'], 'filters': {'event_type': 'clipboard_observed'}})
        self.assertEqual(self.call(5, {'filters': {'device_id': self.b}})['events'], [])

    def test_wsgi_content_type_length_capabilities_no_policy_leak(self):
        statuses = []
        def run(method, path, raw=b'', **fields):
            env = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'CONTENT_LENGTH': str(len(raw)), 'CONTENT_TYPE': 'application/json', 'wsgi.input': io.BytesIO(raw)}
            env.update(fields)
            body = b''.join(self.app(env, lambda status, headers: statuses.append(status)))
            return decode(body)
        result = run('GET', '/v1/activity/capabilities')
        self.assertEqual(result['storage'], 'server_plaintext')
        self.assertNotIn('group', result)
        error = run('POST', '/v1/activity/rpc', b'{}', CONTENT_TYPE='text/plain')
        self.assertEqual(error['error'], 'content_type')
        self.assertTrue(statuses[-1].startswith('415'))
        result = run('POST', '/v1/activity/rpc', encode(self.envelope(1, {})))
        self.assertEqual(result['result']['group'], self.group)

    def test_group_quota_rejects_batch_atomically_and_does_not_stop_status(self):
        self.call(2, {'expected_version': 0, 'enabled': True, 'retention_days': 30, 'max_group_bytes': 1048576})
        self.call(3, {'expected_version': 0, 'enabled': True, 'providers': ['ime.commit.v1']})
        self.ingest(*[self.event('x' * 140000) for _ in range(3)])
        self.ingest(*[self.event('x' * 140000) for _ in range(3)])
        self.assert_error('group_capacity', 4, {'batch_id': identifier(), 'events': [self.event('x' * 140000), self.event('x' * 140000)]})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM events').fetchone()[0], 6)
        self.assertTrue(self.call(1, {})['enabled'])

    def test_fixed_interop_vector_canonical_and_signature(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        vector = decode((SERVER / 'activity_archive/fixtures/activity-request-v1.json').read_bytes())
        request = vector['envelope']
        raw = base64.b64decode(request['body'])
        canonical = request_canonical(request, raw)
        self.assertEqual(canonical.hex(), vector['canonical_hex'])
        self.assertEqual(raw.decode(), vector['body_utf8'])
        Ed25519PublicKey.from_public_bytes(base64.b64decode(vector['public_base64'])).verify(base64.b64decode(request['signature']), canonical)

    def test_real_loopback_http_round_trip_has_exact_signed_ack(self):
        import threading
        from urllib.request import Request, urlopen
        from wsgiref.simple_server import make_server, WSGIRequestHandler
        class QuietHandler(WSGIRequestHandler):
            def log_message(self, *args):
                pass
        self.enable()
        event = self.event('合成HTTP归档')
        server = make_server('127.0.0.1', 0, self.app, handler_class=QuietHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            raw = encode(self.envelope(4, {'batch_id': identifier(), 'events': [event]}))
            request = Request('http://127.0.0.1:' + str(server.server_port) + '/v1/activity/rpc', data=raw, headers={'Content-Type': 'application/json'})
            with urlopen(request, timeout=5) as response:
                result = decode(response.read())
            self.assertEqual(result['result']['accepted_event_ids'], [event['event_id']])
            self.assertEqual(self.call(5, {})['events'][0]['content']['text'], '合成HTTP归档')
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()

    def test_activity_metadata_only_after_successful_ingest_and_current_exact_key(self):
        public = self.keys[self.a].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.call(1, {})
        self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, public, now=self.now))
        self.assert_error('archive_disabled', 4, {'batch_id': identifier(), 'events': [self.event()]})
        self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, public, now=self.now))
        self.enable()
        self.ingest(self.event())
        self.assertEqual(latest_authorized_activity(self.path, self.group, self.a, public, now=self.now), self.now)
        self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, bytes(32), now=self.now))
        self.assertIsNone(latest_authorized_activity(self.path, self.other_group, self.a, public, now=self.now))
        self.store.db.execute('UPDATE member_activity SET last_seen=?', (self.now + 1,))
        self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, public, now=self.now))
        self.assertIsNone(latest_authorized_activity(Path(self.temp.name) / 'missing.sqlite', self.group, self.a, public, now=self.now))

    def test_delegate_ingest_touches_primary_key_activity_metadata(self):
        self.enable()
        key = Ed25519PrivateKey.generate()
        self.call(11, {'expected_consent_version': 1, 'public_key': base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()})
        self.delegate_request(4, {'batch_id': identifier(), 'events': [self.event()]}, key)
        primary = self.keys[self.a].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.assertEqual(latest_authorized_activity(self.path, self.group, self.a, primary, now=self.now), self.now)
        delegate_public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.assertIsNone(latest_authorized_activity(self.path, self.group, self.a, delegate_public, now=self.now))

    def test_metadata_helper_rejects_wrong_schema_and_symlink(self):
        wrong = Path(self.temp.name) / 'wrong.sqlite'
        db = sqlite3.connect(wrong)
        db.execute('CREATE TABLE metadata(key TEXT,value BLOB)')
        db.execute("INSERT INTO metadata VALUES('archive_schema_version',?)", (b'0',))
        db.commit(); db.close()
        public = self.keys[self.a].public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.assertIsNone(latest_authorized_activity(wrong, self.group, self.a, public, now=self.now))
        link = Path(self.temp.name) / 'link.sqlite'
        link.symlink_to(self.path)
        self.assertIsNone(latest_authorized_activity(link, self.group, self.a, public, now=self.now))

    def test_local_proxy_refuses_public_direct_access(self):
        proxy = LocalArchiveProxy(self.app)
        status = []
        result = b''.join(proxy({'REMOTE_ADDR': '203.0.113.12'}, lambda s, h: status.append(s)))
        self.assertTrue(status[0].startswith('403'))
        self.assertEqual(decode(result)['error'], 'proxy_required')


class RelayAuthorityTests(unittest.TestCase):
    def test_existing_signed_membership_read_only_anchor_revocation_and_expiry(self):
        from private_input_relay import Relay
        directory = ROOT / 'build/evidence/activity_archive'
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            path = Path(temporary) / 'relay.sqlite'
            fixture = decode((ROOT / 'fixtures/protocol/relay-membership-v1.json').read_bytes())
            relay = Relay(path, clock=lambda: 1000)
            relay.register(fixture['initial'])
            relay.update(fixture['paired']['group'], fixture['paired'])
            group = fixture['paired']['group']
            device = fixture['paired']['members'][1]['device']
            authority = RelayMembershipAuthority(path)
            before = relay.db.total_changes
            identity = authority.resolve(group, device, 1000)
            self.assertEqual(identity.sender, device)
            self.assertEqual(relay.db.total_changes, before)
            relay.db.execute('INSERT OR REPLACE INTO departed_devices VALUES(?,?,?)', (group, device, 'left'))
            with self.assertRaises(ArchiveError) as caught:
                authority.resolve(group, device, 1000)
            self.assertEqual(caught.exception.code, 'member_inactive')
            relay.db.execute('DELETE FROM departed_devices WHERE group_id=? AND device=?', (group, device))
            relay.db.execute("UPDATE device_profiles SET kind='ios',last_seen=1000,idle_days=1 WHERE group_id=? AND device=?", (group, device))
            with self.assertRaises(ArchiveError):
                authority.resolve(group, device, 1000 + 86401)
            relay.db.execute('UPDATE groups SET digest=? WHERE id=?', (bytes(32), group))
            with self.assertRaises(ArchiveError) as caught:
                authority.resolve(group, device, 1000)
            self.assertEqual(caught.exception.code, 'membership_anchor')
            relay.db.close()


    def test_archived_ingest_activity_extends_same_key_current_member_only(self):
        from private_input_relay import Relay
        directory = ROOT / 'build/evidence/activity_archive'
        directory.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=directory) as temporary:
            relay_path, archive_path = Path(temporary) / 'relay.sqlite', Path(temporary) / 'archive.sqlite'
            fixture = decode((ROOT / 'fixtures/protocol/relay-membership-v1.json').read_bytes())
            relay = Relay(relay_path, clock=lambda: 1000)
            relay.register(fixture['initial'])
            relay.update(fixture['paired']['group'], fixture['paired'])
            group, member = fixture['paired']['group'], fixture['paired']['members'][1]
            device = member['device']
            public = base64.b64decode(member['signingPublic'])
            relay.db.execute("UPDATE device_profiles SET kind='ios',last_seen=1000,idle_days=1 WHERE group_id=? AND device=?", (group, device))
            store = ArchiveStore(archive_path)
            store.db.execute('INSERT INTO member_activity VALUES(?,?,?,?)', (group, device, hashlib.sha256(public).digest(), 1000 + 86400))
            authority = RelayMembershipAuthority(relay_path, activity_database=archive_path)
            self.assertEqual(authority.resolve(group, device, 1000 + 86401).sender, device)
            relay.db.execute('INSERT OR REPLACE INTO departed_devices VALUES(?,?,?)', (group, device, 'left'))
            with self.assertRaises(ArchiveError):
                authority.resolve(group, device, 1000 + 86401)
            relay.db.execute('DELETE FROM departed_devices WHERE group_id=? AND device=?', (group, device))
            store.db.execute('UPDATE member_activity SET member_key_fingerprint=?', (bytes(32),))
            with self.assertRaises(ArchiveError):
                authority.resolve(group, device, 1000 + 86401)
            store.close(); relay.db.close()


if __name__ == '__main__':
    unittest.main()
