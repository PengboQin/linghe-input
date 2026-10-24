"""Explicit, incremental group learning. Never reads raw activity/clipboard text.

Separate SQLite and request domain; existing Relay and archive are read-only
membership authorities, not learning inputs. No HTTP response prints plaintext
into logs; no background threads start implicitly.
"""
import base64
from contextlib import contextmanager
import hashlib
import hmac
import json
import math
from pathlib import Path
import re
import sqlite3
import struct
import threading
import time
import uuid

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from activity_archive.service import ArchiveError, decode, encode, fail, number, shape, uid, unb64
from .authority import fingerprint
from . import components
from . import capacity

DOMAIN = b'PrivateInput/cloud-learning-request/v1\0'
ALGORITHM = 'shared-lexeme-decay-v2'
CHARSET_SHA256 = '668f69e856c357157720ab5a6f8644dca8a253b439772f92cd762b186a53b421'
MAX_WRAPPER = 1048576
MAX_EVENTS = 128
MAX_TERMS = capacity.CURRENT.distinct_terms
MAX_EVENT_ROWS = 100000
MAX_WEIGHT = 200000
HALF_LIFE = 14 * 86400


def canonical(envelope, body):
    return (DOMAIN + b'\x01' + uuid.UUID(envelope['group']).bytes
            + uuid.UUID(envelope['sender']).bytes + uuid.UUID(envelope['nonce']).bytes
            + struct.pack('>Q', envelope['issuedAt']) + bytes([envelope['operation']])
            + hashlib.sha256(body).digest())


def load_charset(path=None):
    path = Path(path) if path else Path(__file__).resolve().parents[2] / 'resources/rime/charset/standard-8105.txt'
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != CHARSET_SHA256:
        raise ValueError('cloud learning charset checksum mismatch')
    values = raw.decode('utf-8').splitlines()
    if len(values) != 8105 or any(len(v) != 1 for v in values) or len(set(values)) != 8105:
        raise ValueError('cloud learning charset shape')
    return frozenset(values)


class LearningStore:
    def __init__(self, database, *, clock=time.time, charset_path=None):
        self.path, self.clock = Path(database), clock
        self.charset = load_charset(charset_path)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(database), isolation_level=None, check_same_thread=False, timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA journal_size_limit=8388608')
        self.db.execute('PRAGMA max_page_count=262144')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS cl_groups(group_id TEXT PRIMARY KEY,policy_version INTEGER NOT NULL,enabled INTEGER NOT NULL,generation INTEGER NOT NULL,model_version INTEGER NOT NULL DEFAULT 0,last_tick INTEGER NOT NULL DEFAULT 0,last_decay INTEGER NOT NULL DEFAULT 0,event_cursor INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS cl_consents(group_id TEXT NOT NULL,device_id TEXT NOT NULL,version INTEGER NOT NULL,enabled INTEGER NOT NULL,installation_id TEXT NOT NULL,fingerprint TEXT NOT NULL,PRIMARY KEY(group_id,device_id));
        CREATE TABLE IF NOT EXISTS cl_devices(group_id TEXT NOT NULL,generation INTEGER NOT NULL,device_id TEXT NOT NULL,installation_id TEXT NOT NULL,consent_version INTEGER NOT NULL,received_seq INTEGER NOT NULL DEFAULT 0,applied_seq INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,generation,device_id,installation_id,consent_version));
        CREATE TABLE IF NOT EXISTS cl_terms(group_id TEXT NOT NULL,generation INTEGER NOT NULL,reading TEXT NOT NULL,text TEXT NOT NULL,layout TEXT NOT NULL,term_generation INTEGER NOT NULL DEFAULT 0,removed INTEGER NOT NULL DEFAULT 0,pinned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,generation,reading,text,layout));
        CREATE TABLE IF NOT EXISTS cl_applied_terms(group_id TEXT NOT NULL,generation INTEGER NOT NULL,reading TEXT NOT NULL,text TEXT NOT NULL,layout TEXT NOT NULL,term_generation INTEGER NOT NULL DEFAULT 0,removed INTEGER NOT NULL DEFAULT 0,pinned INTEGER NOT NULL DEFAULT 0,pin_device TEXT,pin_consent INTEGER,PRIMARY KEY(group_id,generation,reading,text,layout));
        CREATE TABLE IF NOT EXISTS cl_events(row_id INTEGER PRIMARY KEY AUTOINCREMENT,group_id TEXT NOT NULL,generation INTEGER NOT NULL,device_id TEXT NOT NULL,installation_id TEXT NOT NULL,consent_version INTEGER NOT NULL,event_id TEXT NOT NULL,device_seq INTEGER NOT NULL,event_json BLOB NOT NULL,event_hash TEXT NOT NULL,received_at INTEGER NOT NULL,rejected_reason TEXT,UNIQUE(group_id,event_id),UNIQUE(group_id,generation,device_id,installation_id,consent_version,device_seq));
        CREATE INDEX IF NOT EXISTS cl_event_watermark ON cl_events(group_id,generation,row_id);
        CREATE TABLE IF NOT EXISTS cl_contributions(group_id TEXT NOT NULL,generation INTEGER NOT NULL,device_id TEXT NOT NULL,installation_id TEXT NOT NULL,consent_version INTEGER NOT NULL,reading TEXT NOT NULL,text TEXT NOT NULL,layout TEXT NOT NULL,term_generation INTEGER NOT NULL,value REAL NOT NULL,decayed_at INTEGER NOT NULL,PRIMARY KEY(group_id,generation,device_id,installation_id,consent_version,reading,text,layout));
        CREATE TABLE IF NOT EXISTS cl_models(group_id TEXT NOT NULL,generation INTEGER NOT NULL,reading TEXT NOT NULL,text TEXT NOT NULL,layout TEXT NOT NULL,term_generation INTEGER NOT NULL,weight INTEGER NOT NULL,pinned INTEGER NOT NULL,PRIMARY KEY(group_id,generation,reading,text,layout));
        CREATE TABLE IF NOT EXISTS cl_tombstones(group_id TEXT NOT NULL,generation INTEGER NOT NULL,reading TEXT NOT NULL,text TEXT NOT NULL,layout TEXT NOT NULL,term_generation INTEGER NOT NULL,PRIMARY KEY(group_id,generation,reading,text,layout));
        CREATE TABLE IF NOT EXISTS cl_versions(group_id TEXT NOT NULL,generation INTEGER NOT NULL,version INTEGER NOT NULL,changes BLOB NOT NULL,watermarks BLOB NOT NULL,model_sha256 TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(group_id,generation,version));
        CREATE TABLE IF NOT EXISTS cl_nonces(group_id TEXT NOT NULL,device_id TEXT NOT NULL,nonce TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(group_id,device_id,nonce));
        ''')
        components.initialize(self.db)
        if str(database) != ':memory:':
            self.path.chmod(0o600)
            for suffix in ('-wal', '-shm'):
                sidecar = Path(str(database) + suffix)
                if sidecar.exists(): sidecar.chmod(0o600)

    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK')
            raise

    def close(self):
        with self.lock:
            self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            self.db.close()

    def group(self, group):
        self.db.execute('INSERT OR IGNORE INTO cl_groups(group_id,policy_version,enabled,generation) VALUES(?,0,0,0)', (group,))
        return self.db.execute('SELECT * FROM cl_groups WHERE group_id=?', (group,)).fetchone()

    def consent(self, who):
        row = self.db.execute('SELECT * FROM cl_consents WHERE group_id=? AND device_id=?', (who.group, who.sender)).fetchone()
        if row is None: return None
        active = bool(row['enabled']) and hmac.compare_digest(row['fingerprint'], fingerprint(who))
        return {'version': row['version'], 'enabled': active, 'installation_id': row['installation_id']}

    def status(self, who):
        group = self.group(who.group)
        return {'enabled': bool(group['enabled']), 'policy_version': group['policy_version'],
                'generation': group['generation'], 'model_version': group['model_version'],
                'consent': self.consent(who), 'algorithm_version': ALGORITHM,
                'capacity': {
                    'event_rows': self.db.execute('SELECT COUNT(*) FROM cl_events WHERE group_id=?', (who.group,)).fetchone()[0],
                    'max_event_rows': MAX_EVENT_ROWS,
                    'term_rows': self.db.execute('SELECT COUNT(*) FROM cl_terms WHERE group_id=? AND generation=?', (who.group, group['generation'])).fetchone()[0],
                    'max_term_rows': capacity.profile_for_group(who.group, group['generation']).distinct_terms,
                    'component_rows': self.db.execute('SELECT COUNT(*) FROM cl_components WHERE group_id=? AND generation=?', (who.group, group['generation'])).fetchone()[0],
                    'max_component_rows': components.MAX_COMPONENT_ROWS,
                    'producer_count': self.db.execute('SELECT COUNT(*) FROM cl_producers WHERE group_id=? AND generation=?', (who.group, group['generation'])).fetchone()[0],
                    'pending_events': self.db.execute('SELECT COUNT(*) FROM cl_events WHERE group_id=? AND generation=? AND row_id>?', (who.group, group['generation'], group['event_cursor'])).fetchone()[0]}}

    def require_enabled(self, who):
        group, consent = self.group(who.group), self.consent(who)
        if not group['enabled']: fail('learning_disabled', 403)
        if not consent or not consent['enabled']: fail('learning_consent_disabled', 403)
        return group, consent

    def process(self, who, operation, body, nonce):
        if not who.permissions & 1: fail('learning_permission', 403)
        with self.lock, self.transaction():
            now = int(self.clock())
            self.db.execute('DELETE FROM cl_nonces WHERE expires<?', (now,))
            try:
                self.db.execute('INSERT INTO cl_nonces VALUES(?,?,?,?)', (who.group, who.sender, nonce, now + 600))
            except sqlite3.IntegrityError:
                fail('nonce_replay', 409)
            if operation == 1:
                shape(body)
                return self.status(who)
            if operation == 2:
                shape(body, ('expected_version', 'enabled'))
                if not who.permissions & 2 or not getattr(who,'can_manage',True): fail('learning_admin_permission', 403)
                if type(body['enabled']) is not bool: fail('boolean')
                group = self.group(who.group)
                if number(body['expected_version']) != group['policy_version']: fail('policy_stale', 409)
                # No-op policy saves do not churn generations or wipe learning.
                if body['enabled'] != bool(group['enabled']):
                    self.db.execute('UPDATE cl_groups SET policy_version=policy_version+1,enabled=?,generation=generation+1,model_version=0,event_cursor=0,last_tick=0,last_decay=0 WHERE group_id=?', (int(body['enabled']), who.group))
                    self.db.execute('UPDATE cl_consents SET enabled=0,version=version+1 WHERE group_id=?', (who.group,))
                return self.status(who)
            if operation == 3:
                shape(body, ('expected_version', 'enabled', 'installation_id'))
                if type(body['enabled']) is not bool: fail('boolean')
                install = uid(body['installation_id'])
                group = self.group(who.group)
                consent = self.consent(who)
                if number(body['expected_version']) != (consent['version'] if consent else 0): fail('consent_stale', 409)
                if body['enabled'] and not group['enabled']: fail('learning_disabled', 403)
                version = (consent['version'] if consent else 0) + 1
                self.db.execute('INSERT OR REPLACE INTO cl_consents VALUES(?,?,?,?,?,?)', (who.group, who.sender, version, int(body['enabled']), install, fingerprint(who)))
                return self.status(who)
            if operation == 4: return self.ingest(who, body)
            if operation == 5: return self.pull(who, body)
            if operation == 6: return components.ingest(self, who, body)
            if operation == 7: return components.bootstrap(self, who, body)
            fail('operation')

    def term_key(self, event):
        reading, text, layout = (event[k] for k in ('reading', 'text', 'layout'))
        if type(reading) is not str or not 1 <= len(reading) <= 96 or not re.fullmatch(r"[a-z]+(?:[ '][a-z]+)*", reading): fail('reading')
        if type(text) is not str or not 1 <= len(text) <= 32 or not any(c in self.charset for c in text): fail('term_text')
        if any(c not in self.charset and not (c.isascii() and (c.isalnum() or c in " -'._")) for c in text): fail('simplified_term_required')
        if layout not in ('pinyin26', 't9'): fail('layout')
        return reading, text, 'shared'

    def ingest(self, who, body):
        shape(body, ('generation', 'consent_version', 'installation_id', 'events'))
        group, consent = self.require_enabled(who)
        generation = number(body['generation'])
        if generation != group['generation']: fail('generation_stale', 409)
        cv, install = number(body['consent_version']), uid(body['installation_id'])
        if cv != consent['version'] or install != consent['installation_id']: fail('consent_stale', 409)
        events = body['events']
        if type(events) is not list or not 1 <= len(events) <= MAX_EVENTS: fail('batch_size', 413)
        device_key = (who.group, generation, who.sender, install, cv)
        self.db.execute('INSERT OR IGNORE INTO cl_devices(group_id,generation,device_id,installation_id,consent_version) VALUES(?,?,?,?,?)', device_key)
        sequence = self.db.execute('SELECT received_seq FROM cl_devices WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=?', device_key).fetchone()[0]
        accepted, controls, rejected = [], [], []
        for event in events:
            shape(event, ('event_id', 'device_seq', 'kind', 'reading', 'text', 'layout', 'term_generation', 'observed_at'), ('count',))
            event_id = uid(event['event_id']); seq = number(event['device_seq'], 1)
            kind = event['kind']
            if kind not in ('confirm', 'reset', 'remove', 'restore', 'pin', 'unpin'): fail('learning_event_kind')
            reading, text, layout = self.term_key(event)
            tg = number(event['term_generation'])
            number(event['observed_at'], 0, (1 << 53) - 1)
            count = number(event.get('count', 1), 1, 64)
            if kind != 'confirm' and 'count' in event: fail('control_count')
            event_raw = encode(event); digest = hashlib.sha256(event_raw).hexdigest()
            old = self.db.execute('SELECT * FROM cl_events WHERE group_id=? AND event_id=?', (who.group, event_id)).fetchone()
            if old:
                if old['event_hash'] != digest or old['device_id'] != who.sender or old['installation_id'] != install or old['generation'] != generation or old['consent_version'] != cv:
                    fail('event_conflict', 409)
                if old['rejected_reason']:
                    rejected.append({'event_id': event_id, 'reason': old['rejected_reason']})
                else:
                    accepted.append(event_id)
                    if kind in ('reset', 'remove', 'restore'):
                        controls.append({'reading': reading, 'text': text, 'layout': layout, 'term_generation': tg + 1})
                continue
            if seq != sequence + 1: fail('device_sequence_gap', 409)
            if self.db.execute('SELECT COUNT(*) FROM cl_events WHERE group_id=?', (who.group,)).fetchone()[0] >= MAX_EVENT_ROWS: fail('learning_capacity', 503)
            term_key = (who.group, generation, reading, text, layout)
            term = self.db.execute('SELECT * FROM cl_terms WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', term_key).fetchone()
            if term is None:
                capacity.require_term_admission(self.db, who.group, generation, reading, text)
                self.db.execute('INSERT INTO cl_terms(group_id,generation,reading,text,layout) VALUES(?,?,?,?,?)', term_key)
                term = self.db.execute('SELECT * FROM cl_terms WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', term_key).fetchone()
            rejection = 'term_generation_stale' if tg != term['term_generation'] else ('term_removed' if kind in ('confirm', 'pin') and term['removed'] else None)
            if rejection:
                rejected.append({'event_id': event_id, 'reason': rejection})
                controls.append({'reading': reading, 'text': text, 'layout': layout, 'term_generation': term['term_generation']})
            elif kind in ('reset', 'remove', 'restore'):
                self.db.execute('UPDATE cl_terms SET term_generation=term_generation+1,removed=?,pinned=0 WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (int(kind == 'remove'),) + term_key)
                controls.append({'reading': reading, 'text': text, 'layout': layout, 'term_generation': tg + 1})
            elif kind in ('pin', 'unpin'):
                self.db.execute('UPDATE cl_terms SET pinned=? WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (int(kind == 'pin'),) + term_key)
            self.db.execute('INSERT INTO cl_events(group_id,generation,device_id,installation_id,consent_version,event_id,device_seq,event_json,event_hash,received_at,rejected_reason) VALUES(?,?,?,?,?,?,?,?,?,?,?)', device_key + (event_id, seq, event_raw, digest, int(self.clock()), rejection))
            if not rejection: accepted.append(event_id)
            sequence = seq
        self.db.execute('UPDATE cl_devices SET received_seq=? WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=?', (sequence,) + device_key)
        return {'accepted_event_ids': accepted, 'rejected_event_ids': rejected, 'received_device_seq': sequence, 'generation': generation, 'consent_version': cv, 'term_generations': controls}

    def pull(self, who, body):
        shape(body, ('generation', 'from_version'), ('limit',))
        group, _ = self.require_enabled(who)
        generation, version = number(body['generation']), number(body['from_version'])
        if generation != group['generation']: fail('generation_stale', 409)
        if version > group['model_version']: fail('model_version_future', 409)
        limit = number(body.get('limit', 8), 1, 8)
        changes = {}
        if version == 0 and group['model_version'] > 0:
            # First join / lost-index recovery needs one bounded current model,
            # not hundreds of repeated hourly-decay deltas from day one.
            rows = self.db.execute('SELECT * FROM cl_versions WHERE group_id=? AND generation=? AND version=?', (who.group, generation, group['model_version'])).fetchall()
            if not rows: fail('model_state_mismatch', 503)
            for row in self.db.execute('SELECT * FROM cl_models WHERE group_id=? AND generation=?', (who.group, generation)):
                item = {k: row[k] for k in ('reading', 'text', 'layout', 'term_generation', 'weight')}
                item.update(pinned=bool(row['pinned']), deleted=False)
                changes[(item['layout'], item['reading'], item['text'])] = item
            for row in self.db.execute('SELECT * FROM cl_tombstones WHERE group_id=? AND generation=?', (who.group, generation)):
                item = {k: row[k] for k in ('reading', 'text', 'layout', 'term_generation')}
                item['deleted'] = True
                changes[(item['layout'], item['reading'], item['text'])] = item
        else:
            rows = self.db.execute('SELECT * FROM cl_versions WHERE group_id=? AND generation=? AND version>? ORDER BY version LIMIT ?', (who.group, generation, version, limit)).fetchall()
            for row in rows:
                for item in decode(row['changes']): changes[(item['layout'], item['reading'], item['text'])] = item
        target = rows[-1]['version'] if rows else version
        last = rows[-1] if rows else self.db.execute('SELECT * FROM cl_versions WHERE group_id=? AND generation=? AND version=?', (who.group, generation, target)).fetchone()
        watermarks = decode(last['watermarks']) if last else []
        producer_marks = decode(last['producer_watermarks']) if last else []
        digest = last['model_sha256'] if last else self.model_hash(generation, [], [], [])
        ordered = [changes[k] for k in sorted(changes)]
        result = {'generation': generation, 'from_version': version, 'to_version': target,
                'upserts': [{k: v for k, v in x.items() if k != 'deleted'} for x in ordered if not x['deleted']],
                'tombstones': [{k: v for k, v in x.items() if k not in ('deleted', 'weight', 'pinned')} for x in ordered if x['deleted']],
                'watermarks': watermarks, 'producer_watermarks': producer_marks, 'model_sha256': digest, 'has_more': target < group['model_version'], 'algorithm_version': ALGORITHM}
        profile = capacity.profile_for_group(who.group, generation)
        if len(result['upserts']) > profile.model_terms or len(result['tombstones']) > profile.model_terms: fail('model_capacity', 503)
        if len(encode(result)) > profile.response_bytes: fail('response_size', 413)
        return result

    @staticmethod
    def model_hash(generation, entries, watermarks, producer_watermarks=None):
        return hashlib.sha256(encode({'generation': generation, 'algorithm_version': ALGORITHM, 'upserts': entries, 'watermarks': watermarks, 'producer_watermarks': producer_watermarks or []})).hexdigest()

    def worker_tick(self, authority, *, force=False, event_limit=1024, group_limit=16):
        """Bounded one-shot batch; caller schedules, never runs on HTTP/input path."""
        number(event_limit, 1, 4096)
        number(group_limit, 1, 64)
        now = int(self.clock()); summary = {'groups_checked': 0, 'groups_published': 0, 'events_consumed': 0}
        with self.lock, self.transaction():
            due_before = now if force else now - 600
            for group in self.db.execute('SELECT * FROM cl_groups WHERE enabled=1 AND last_tick<=? ORDER BY last_tick,group_id LIMIT ?', (due_before, group_limit)).fetchall():
                summary['groups_checked'] += 1
                published, consumed = self.aggregate_group(group, authority, now, event_limit)
                summary['groups_published'] += int(published)
                summary['events_consumed'] += consumed
        return summary

    def aggregate_group(self, group, authority, now, event_limit):
        gid, generation = group['group_id'], group['generation']
        # Re-resolve current active membership/key before using a contribution or
        # queued event. Revocation removes derived weights; raw event log remains.
        valid = {}
        for consent in self.db.execute('SELECT * FROM cl_consents WHERE group_id=? AND enabled=1', (gid,)).fetchall():
            try:
                who = authority.resolve(gid, consent['device_id'], now)
                if who.permissions & 1 and hmac.compare_digest(consent['fingerprint'], fingerprint(who)):
                    valid[(consent['device_id'], consent['installation_id'], consent['version'])] = who
            except ArchiveError:
                pass
        for row in self.db.execute('SELECT DISTINCT device_id,installation_id,consent_version FROM cl_contributions WHERE group_id=? AND generation=?', (gid, generation)).fetchall():
            if tuple(row) not in valid:
                self.db.execute('DELETE FROM cl_contributions WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=?', (gid, generation) + tuple(row))
        # Pin authority cannot remain after its issuing device loses consent or
        # membership. Resets/deletions remain fences rather than undoing privacy.
        for row in self.db.execute('SELECT rowid,pin_device,pin_consent FROM cl_applied_terms WHERE group_id=? AND generation=? AND pinned=1', (gid, generation)).fetchall():
            if not any(key[0] == row['pin_device'] and key[2] == row['pin_consent'] for key in valid):
                self.db.execute('UPDATE cl_applied_terms SET pinned=0 WHERE rowid=?', (row['rowid'],))
        rows = self.db.execute('SELECT * FROM cl_events WHERE group_id=? AND generation=? AND row_id>? ORDER BY row_id LIMIT ?', (gid, generation, group['event_cursor'], event_limit)).fetchall()
        cursor = group['event_cursor']
        for row in rows:
            cursor = row['row_id']; event = decode(row['event_json'])
            dkey = (row['device_id'], row['installation_id'], row['consent_version'])
            # Accepted privacy/control fences remain durable after the issuing
            # member departs. Positive learning and pin privileges do not.
            if dkey not in valid and event['kind'] not in ('reset', 'remove', 'restore'): continue
            if row['rejected_reason']:
                self.db.execute('UPDATE cl_devices SET applied_seq=? WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=?', (row['device_seq'], gid, generation) + dkey)
                continue
            tkey = (gid, generation, event['reading'], event['text'], 'shared')
            self.db.execute('INSERT OR IGNORE INTO cl_applied_terms(group_id,generation,reading,text,layout) VALUES(?,?,?,?,?)', tkey)
            term = self.db.execute('SELECT * FROM cl_applied_terms WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', tkey).fetchone()
            if event['kind'] in ('reset', 'remove', 'restore'):
                self.db.execute('UPDATE cl_applied_terms SET term_generation=?,removed=?,pinned=0,pin_device=NULL,pin_consent=NULL WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (event['term_generation'] + 1, int(event['kind'] == 'remove')) + tkey)
                self.db.execute('DELETE FROM cl_contributions WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', tkey)
            elif event['kind'] in ('pin', 'unpin') and event['term_generation'] == term['term_generation']:
                self.db.execute('UPDATE cl_applied_terms SET pinned=?,pin_device=?,pin_consent=? WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (int(event['kind'] == 'pin'), row['device_id'], row['consent_version']) + tkey)
            elif event['kind'] == 'confirm' and not term['removed'] and term['term_generation'] == event['term_generation']:
                ckey = (gid, generation) + dkey + (event['reading'], event['text'], 'shared')
                old = self.db.execute('SELECT value,decayed_at FROM cl_contributions WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=? AND reading=? AND text=? AND layout=?', ckey).fetchone()
                # Device clock cannot boost future terms; stale/offline data gets
                # limited recency rather than being mistaken for fresh usage.
                observed = min(row['received_at'], event['observed_at'])
                age = max(0, now - max(observed, row['received_at'] - 90 * 86400))
                value = event.get('count', 1) * 1000 * math.pow(2.0, -age / HALF_LIFE)
                if old: value += old['value'] * math.pow(2.0, -max(0, now - old['decayed_at']) / HALF_LIFE)
                self.db.execute('INSERT OR REPLACE INTO cl_contributions VALUES(?,?,?,?,?,?,?,?,?,?,?)', ckey + (term['term_generation'], min(value, MAX_WEIGHT), now))
            self.db.execute('UPDATE cl_devices SET applied_seq=? WHERE group_id=? AND generation=? AND device_id=? AND installation_id=? AND consent_version=?', (row['device_seq'], gid, generation) + dkey)
        decay = now - group['last_decay'] >= 3600
        if decay:
            for row in self.db.execute('SELECT rowid,value,decayed_at FROM cl_contributions WHERE group_id=? AND generation=?', (gid, generation)).fetchall():
                value = row['value'] * math.pow(2.0, -max(0, now - row['decayed_at']) / HALF_LIFE)
                self.db.execute('UPDATE cl_contributions SET value=?,decayed_at=? WHERE rowid=?', (value, now, row['rowid']))
        desired = {}
        for term in self.db.execute('SELECT * FROM cl_applied_terms WHERE group_id=? AND generation=? AND removed=0', (gid, generation)):
            total = self.db.execute('SELECT COALESCE(SUM(value),0) FROM cl_contributions WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=? AND term_generation=?', (gid, generation, term['reading'], term['text'], term['layout'], term['term_generation'])).fetchone()[0]
            weight = min(MAX_WEIGHT, max(0, int(total)))
            item = {k: term[k] for k in ('reading', 'text', 'layout', 'term_generation')}
            item.update(weight=weight, pinned=bool(term['pinned']))
            desired[(term['layout'], term['reading'], term['text'])] = item
        native_active, native_deleted, producer_marks = components.projection(self, gid, generation, valid, now, decay_due=decay)
        for key, item in native_active.items():
            local = desired.get(key)
            if local is None or item['term_generation'] > local['term_generation']: desired[key] = item
            elif item['term_generation'] == local['term_generation']:
                desired[key] = dict(item, weight=min(MAX_WEIGHT, item['weight'] + local['weight']), pinned=item['pinned'] or local['pinned'])
        for key, item in native_deleted.items():
            if key not in desired or item['term_generation'] >= desired[key]['term_generation']: desired.pop(key, None)
        old = {}
        for row in self.db.execute('SELECT * FROM cl_models WHERE group_id=? AND generation=?', (gid, generation)):
            item = {k: row[k] for k in ('reading', 'text', 'layout', 'term_generation', 'weight')}; item['pinned'] = bool(row['pinned'])
            old[(row['layout'], row['reading'], row['text'])] = item
        changes = []
        for key in sorted(set(old) | set(desired)):
            if key in desired and desired[key] != old.get(key): changes.append(dict(desired[key], deleted=False))
            elif key not in desired:
                term = self.db.execute('SELECT term_generation FROM cl_applied_terms WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (gid, generation, key[1], key[2], key[0])).fetchone()
                changes.append({'reading': key[1], 'text': key[2], 'layout': key[0], 'term_generation': max(term[0] if term else old[key]['term_generation'], native_deleted.get(key, {}).get('term_generation', 0)), 'deleted': True})
        for term in self.db.execute('SELECT * FROM cl_applied_terms WHERE group_id=? AND generation=? AND removed=1', (gid, generation)).fetchall():
            tomb = self.db.execute('SELECT term_generation FROM cl_tombstones WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (gid, generation, term['reading'], term['text'], term['layout'])).fetchone()
            key = (term['layout'], term['reading'], term['text'])
            if (not tomb or tomb[0] != term['term_generation']) and key not in old:
                changes.append({k: term[k] for k in ('reading', 'text', 'layout', 'term_generation')} | {'deleted': True})
        for key, item in native_deleted.items():
            tomb = self.db.execute('SELECT term_generation FROM cl_tombstones WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (gid, generation, item['reading'], item['text'], 'shared')).fetchone()
            if key not in old and (not tomb or tomb[0] != item['term_generation']): changes.append(dict(item, deleted=True))
        watermarks = []
        for row in self.db.execute('SELECT * FROM cl_devices WHERE group_id=? AND generation=? ORDER BY device_id,installation_id,consent_version', (gid, generation)):
            if (row['device_id'], row['installation_id'], row['consent_version']) in valid:
                watermarks.append({k: row[k] for k in ('device_id', 'installation_id', 'consent_version')} | {'device_seq': row['applied_seq']})
        previous = self.db.execute('SELECT watermarks,producer_watermarks FROM cl_versions WHERE group_id=? AND generation=? AND version=?', (gid, generation, group['model_version'])).fetchone()
        published = bool(changes) or watermarks != (decode(previous[0]) if previous else []) or producer_marks != (decode(previous[1]) if previous else [])
        if published:
            version = group['model_version'] + 1
            self.db.execute('DELETE FROM cl_models WHERE group_id=? AND generation=?', (gid, generation))
            for key in sorted(desired):
                item = desired[key]
                self.db.execute('INSERT INTO cl_models VALUES(?,?,?,?,?,?,?,?)', (gid, generation, item['reading'], item['text'], item['layout'], item['term_generation'], item['weight'], int(item['pinned'])))
                self.db.execute('DELETE FROM cl_tombstones WHERE group_id=? AND generation=? AND reading=? AND text=? AND layout=?', (gid, generation, item['reading'], item['text'], item['layout']))
            for item in changes:
                if item['deleted']:
                    self.db.execute('INSERT OR REPLACE INTO cl_tombstones VALUES(?,?,?,?,?,?)', (gid, generation, item['reading'], item['text'], item['layout'], item['term_generation']))
            digest = self.model_hash(generation, [desired[k] for k in sorted(desired)], watermarks, producer_marks)
            self.db.execute('INSERT INTO cl_versions(group_id,generation,version,changes,watermarks,model_sha256,created_at,producer_watermarks) VALUES(?,?,?,?,?,?,?,?)', (gid, generation, version, encode(changes), encode(watermarks), digest, now, encode(producer_marks)))
            self.db.execute('UPDATE cl_groups SET model_version=? WHERE group_id=?', (version, gid))
        self.db.execute('UPDATE cl_groups SET event_cursor=?,last_tick=?,last_decay=? WHERE group_id=?', (cursor, now, now if decay else group['last_decay'], gid))
        return published, len(rows)


class LearningApplication:
    def __init__(self, store, authority, *, clock=time.time):
        self.store, self.authority, self.clock = store, authority, clock
        self.rates = {}; self.rate_lock = threading.Lock()

    def capabilities(self):
        return {'protocol': 'private-input-cloud-learning', 'version': 1, 'default_enabled': False,
                'algorithm_version': ALGORITHM, 'operations': [1, 2, 3, 4, 5, 6, 7], 'component_protocol': 1, 'own_component_bootstrap': True, 'model_scope': 'shared_lexeme', 'max_batch_events': MAX_EVENTS,
                'max_group_terms': MAX_TERMS, 'aggregate_interval_seconds': 600, 'decay_interval_seconds': 3600,
                'input_sources': ['confirmed_selection', 'explicit_control'], 'clipboard_training': False,
                'charset': 'mainland-standard-8105', 'charset_sha256': CHARSET_SHA256}

    def dispatch(self, raw):
        if len(raw) > MAX_WRAPPER: fail('request_size', 413)
        envelope = decode(raw)
        shape(envelope, ('version', 'group', 'sender', 'nonce', 'issuedAt', 'operation', 'body', 'signature'))
        number(envelope['version'], 1, 1)
        group, sender, nonce = (uid(envelope[k]) for k in ('group', 'sender', 'nonce'))
        number(envelope['issuedAt'], 0, (1 << 64) - 1)
        if abs(self.clock() - envelope['issuedAt']) > 300: fail('request_clock', 401)
        operation = number(envelope['operation'], 1, 7)
        body, signature = unb64(envelope['body']), unb64(envelope['signature'], 64, 64)
        who = self.authority.resolve(group, sender, self.clock())
        try:
            Ed25519PublicKey.from_public_bytes(who.public).verify(signature, canonical(envelope, body))
        except (InvalidSignature, ValueError): fail('signature', 401)
        with self.rate_lock:
            now = self.clock()
            self.rates = {k: v for k, v in self.rates.items() if v[0] > now - 60}
            key = (group, sender); start, count = self.rates.get(key, (now, 0))
            if count >= 120 or len(self.rates) >= 10000 and key not in self.rates: fail('rate_limit', 429)
            self.rates[key] = (start, count + 1)
        return {'version': 1, 'operation': operation, 'result': self.store.process(who, operation, decode(body), nonce)}

    def __call__(self, environ, start_response):
        status = 200
        try:
            path, method = environ.get('PATH_INFO'), environ.get('REQUEST_METHOD')
            if method == 'GET' and path == '/v1/learning/capabilities': response = self.capabilities()
            elif method == 'GET' and path == '/healthz': response = {'service': 'private-input-cloud-learning', 'ready': True}
            elif method == 'POST' and path == '/v1/learning/rpc':
                length = environ.get('CONTENT_LENGTH', '')
                if not length.isdecimal() or not 0 < int(length) <= MAX_WRAPPER: fail('request_size', 413)
                if environ.get('CONTENT_TYPE', '').split(';')[0].strip().lower() != 'application/json': fail('content_type', 415)
                raw = environ['wsgi.input'].read(int(length))
                if len(raw) != int(length): fail('request_length')
                response = self.dispatch(raw)
            else: fail('not_found', 404)
        except ArchiveError as error: status, response = error.status, {'version': 1, 'error': error.code}
        except (sqlite3.Error, OSError): status, response = 503, {'version': 1, 'error': 'learning_unavailable'}
        except Exception: status, response = 500, {'version': 1, 'error': 'internal'}
        from http import HTTPStatus
        raw = encode(response)
        start_response(str(status) + ' ' + HTTPStatus(status).phrase, [('Content-Type', 'application/json; charset=utf-8'), ('Content-Length', str(len(raw))), ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')])
        return [raw]
