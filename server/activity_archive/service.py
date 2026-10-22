"""Signed, tenant-isolated plaintext archive. Request bodies are never logged.

No registration/accounts, model calls or clipboard scraping live in this module.
The caller must explicitly enable a group and its own providers before ingest.
"""
import base64
from contextlib import contextmanager, closing
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import io
import json
from pathlib import Path
import re
import sqlite3
import struct
import threading
import time
import uuid
from urllib.parse import quote

from .metadata import latest_authorized_activity
from .diagnostics import validate_decision_extensions

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

WRAPPER_LIMIT = 1048576
BODY_LIMIT = 524288
EVENT_LIMIT = 262144
MAX_BATCH = 128
MAX_RESPONSE = 1048576
MAX_LEDGER_BYTES = 134217728
ERASE_REASONS = {'unknown': 0, 'retention_expire': 1, 'user_erase': 2}
MAX_INTEGER = (1 << 63) - 1
DOMAIN = b'PrivateInput/activity-request/v1\0'
TYPES = {'input_commit', 'clipboard_observed', 'paste_action', 'text_revise',
         'text_retract', 'source_import', 'coverage_gap'}
REQUIRED = set('schema_version event_id device_group device_id installation_id device_seq provider_id event_type observed_at content consent_version'.split())
OPTIONAL = set('timezone_id utc_offset_minutes input_session editor_epoch span_id edit_op source_kind source_app document_id delivery_state commit_confirmation sensitivity links time_quality extensions'.split())
ID_PATTERN = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')


class ArchiveError(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def fail(code, status=400):
    raise ArchiveError(code, status)


def uid(value):
    if type(value) is not str or len(value) != 36:
        fail('uuid')
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        fail('uuid')
    if str(parsed) != value.lower():
        fail('uuid')
    return str(parsed).upper()


def number(value, low=0, high=MAX_INTEGER):
    if type(value) is not int or not low <= value <= high:
        fail('integer')
    return value


def boolean(value):
    if type(value) is not bool:
        fail('boolean')
    return value


def shape(value, required=(), optional=()):
    if type(value) is not dict or not set(required) <= value.keys() or not value.keys() <= set(required) | set(optional):
        fail('fields')


def encode(value):
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')
    except (ValueError, UnicodeError, TypeError, RecursionError):
        fail('json')


def decode(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                fail('duplicate_field')
            result[key] = value
        return result
    def integer(raw):
        if len(raw) > 20:
            fail('integer')
        return int(raw)
    try:
        return json.loads(data.decode('utf-8'), object_pairs_hook=pairs, parse_int=integer,
                          parse_float=lambda _: fail('integer'), parse_constant=lambda _: fail('json'))
    except (ValueError, UnicodeError, RecursionError):
        fail('json')


def unb64(value, low=0, high=BODY_LIMIT):
    if type(value) is not str or len(value) > 4 * ((high + 2) // 3):
        fail('base64')
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, UnicodeError):
        fail('base64')
    if not low <= len(raw) <= high:
        fail('size', 413)
    return raw


def timestamp(value):
    if type(value) is not str or len(value) > 48 or not re.search(r'(Z|[+-]\d\d:\d\d)$', value):
        fail('timestamp')
    try:
        date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if date.tzinfo is None:
            fail('timestamp')
        return date.timestamp()
    except (ValueError, OverflowError):
        fail('timestamp')


def iso(now):
    return datetime.fromtimestamp(now, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def request_canonical(envelope, body):
    return (DOMAIN + b'\x01' + uuid.UUID(envelope['group']).bytes + uuid.UUID(envelope['sender']).bytes
            + uuid.UUID(envelope['nonce']).bytes + struct.pack('>Q', envelope['issuedAt'])
            + bytes([envelope['operation']]) + hashlib.sha256(body).digest())


@dataclass(frozen=True)
class Identity:
    group: str
    sender: str
    public: bytes
    permissions: int
    revision: int
    digest: bytes
    members: frozenset


class MemoryAuthority:
    """Explicit synthetic-test authority. Never selected by environment defaults."""
    def __init__(self):
        self.groups = {}
    def put(self, group, members, revision=1):
        group = uid(group)
        normalized = {uid(key): value for key, value in members.items()}
        digest = hashlib.sha256(encode({'revision': revision, 'members': {key: [base64.b64encode(value[0]).decode(), value[1]] for key, value in normalized.items()}})).digest()
        self.groups[group] = (normalized, revision, digest)
    def resolve(self, group, sender, now):
        if group not in self.groups:
            fail('group', 403)
        members, revision, digest = self.groups[group]
        if sender not in members:
            fail('member', 403)
        public, permissions = members[sender]
        return Identity(group, sender, public, permissions, revision, digest, frozenset(members))


class RelayMembershipAuthority:
    """Read-only, current signed membership + anchor + departure checks.

    Opens a fresh read-only connection for every request, never initializes Relay
    or changes last_seen. Archive activity does not refresh relay idle deadlines.
    """
    def __init__(self, database, *, activity_database=None):
        self.database = str(Path(database).resolve())
        self.activity_database = activity_database
        if not Path(self.database).is_file():
            raise ValueError('relay database must already exist')
    def resolve(self, group, sender, now):
        # Existing canonical/chain verifier is reused, but the mutable Relay class
        # is deliberately never constructed.
        try:
            from private_input_relay import membership_bytes, strict_json, identifier, b64, RelayError
        except ImportError:
            from ..private_input_relay import membership_bytes, strict_json, identifier, b64, RelayError
        try:
            with closing(sqlite3.connect('file:' + quote(self.database) + '?mode=ro', uri=True, timeout=3)) as db:
                row = db.execute('SELECT root,revision,digest,state FROM groups WHERE id=?', (group,)).fetchone()
                if row is None:
                    fail('group', 403)
                state = strict_json(row[3])
                actual_group, root, digest = membership_bytes(state)
                if actual_group != group or root != row[0] or str(state['revision']) != row[1] or digest != row[2]:
                    fail('membership_anchor', 403)
                tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                members = set()
                selected = None
                for member in state['members']:
                    device = identifier(member['device'])[0]
                    departed = 'departed_devices' in tables and db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?', (group, device)).fetchone()
                    profile = db.execute('SELECT kind,idle_days,last_seen,signing FROM device_profiles WHERE group_id=? AND device=?', (group, device)).fetchone() if 'device_profiles' in tables else None
                    public = b64(member['signingPublic'], 32, 32)
                    archived_activity = latest_authorized_activity(self.activity_database, group, device, public, now=now) if self.activity_database else None
                    last_seen = max(profile[2], archived_activity or 0) if profile else 0
                    expired = profile and profile[0] in {'ios', 'android'} and now - last_seen >= profile[1] * 86400
                    if profile and bytes(profile[3]) != public:
                        fail('membership_profile', 403)
                    if departed or expired:
                        continue
                    members.add(device)
                    if device == sender:
                        selected = member
                if selected is None:
                    fail('member_inactive', 403)
                return Identity(group, sender, b64(selected['signingPublic'], 32, 32), selected['permissions'], state['revision'], digest, frozenset(members))
        except RelayError:
            fail('membership_invalid', 403)
        except sqlite3.Error:
            fail('authority_unavailable', 503)


class ArchiveStore:
    def __init__(self, database, *, clock=time.time, max_database_bytes=1073741824, cursor_ttl=86400):
        self.path = Path(database)
        self.clock = clock
        self.cursor_ttl = cursor_ttl
        self.lock = threading.RLock()
        self.db = sqlite3.connect(str(database), check_same_thread=False, isolation_level=None, timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA secure_delete=ON')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA journal_size_limit=8388608')
        self.db.execute('PRAGMA wal_autocheckpoint=256')
        page_size = self.db.execute('PRAGMA page_size').fetchone()[0]
        self.db.execute('PRAGMA max_page_count=' + str(max_database_bytes // page_size))
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS archive_groups(group_id TEXT PRIMARY KEY, policy_version INTEGER NOT NULL DEFAULT 0, enabled INTEGER NOT NULL DEFAULT 0, retention_days INTEGER NOT NULL DEFAULT 30, max_group_bytes INTEGER NOT NULL DEFAULT 104857600, acl_version INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS device_consents(group_id TEXT NOT NULL REFERENCES archive_groups(group_id),device_id TEXT NOT NULL,version INTEGER NOT NULL,enabled INTEGER NOT NULL,providers BLOB NOT NULL,readers BLOB NOT NULL,PRIMARY KEY(group_id,device_id));
        CREATE TABLE IF NOT EXISTS events(group_id TEXT NOT NULL REFERENCES archive_groups(group_id),event_id TEXT NOT NULL,device_id TEXT NOT NULL,installation_id TEXT NOT NULL,device_seq INTEGER NOT NULL,provider_id TEXT NOT NULL,event_type TEXT NOT NULL,observed_at REAL NOT NULL,received_at REAL NOT NULL,change_seq INTEGER NOT NULL DEFAULT 0,content_hash TEXT NOT NULL,event_json BLOB NOT NULL,size_bytes INTEGER NOT NULL,PRIMARY KEY(group_id,event_id),UNIQUE(group_id,device_id,installation_id,device_seq));
        CREATE INDEX IF NOT EXISTS events_scope ON events(group_id,device_id,change_seq);
        CREATE INDEX IF NOT EXISTS events_observed ON events(group_id,observed_at);
        CREATE INDEX IF NOT EXISTS events_provider ON events(group_id,provider_id,event_type);
        CREATE TABLE IF NOT EXISTS member_activity(group_id TEXT NOT NULL,device_id TEXT NOT NULL,member_key_fingerprint BLOB NOT NULL,last_seen INTEGER NOT NULL,PRIMARY KEY(group_id,device_id));
        CREATE TABLE IF NOT EXISTS capture_keys(group_id TEXT NOT NULL,device_id TEXT NOT NULL,public_key BLOB NOT NULL,member_key_fingerprint BLOB NOT NULL,consent_version INTEGER NOT NULL,PRIMARY KEY(group_id,device_id));
        CREATE TABLE IF NOT EXISTS event_revisions(group_id TEXT NOT NULL,base_event_id TEXT NOT NULL,revision_event_id TEXT NOT NULL,PRIMARY KEY(group_id,revision_event_id));
        CREATE TABLE IF NOT EXISTS ingest_receipts(group_id TEXT NOT NULL,device_id TEXT NOT NULL,batch_id TEXT NOT NULL,body_hash TEXT NOT NULL,event_ids BLOB NOT NULL,created_at REAL NOT NULL,PRIMARY KEY(group_id,device_id,batch_id));
        CREATE TABLE IF NOT EXISTS change_log(seq INTEGER NOT NULL,group_id TEXT NOT NULL,device_id TEXT NOT NULL,event_id TEXT NOT NULL,kind TEXT NOT NULL,created_at REAL NOT NULL,PRIMARY KEY(group_id,seq));
        CREATE INDEX IF NOT EXISTS change_scope ON change_log(group_id,seq);
        CREATE TABLE IF NOT EXISTS deletion_tombstones(group_id TEXT NOT NULL,event_id TEXT NOT NULL,device_id TEXT NOT NULL,installation_id TEXT NOT NULL,device_seq INTEGER NOT NULL,erased_at REAL NOT NULL,PRIMARY KEY(group_id,event_id),UNIQUE(group_id,device_id,installation_id,device_seq));
        CREATE TABLE IF NOT EXISTS erasure_reasons(group_id TEXT NOT NULL,event_id TEXT NOT NULL,reason TEXT NOT NULL CHECK(reason IN ('unknown','retention_expire','user_erase')),PRIMARY KEY(group_id,event_id));
        CREATE TABLE IF NOT EXISTS erasure_revision_links(group_id TEXT NOT NULL,base_event_id TEXT NOT NULL,revision_event_id TEXT NOT NULL,PRIMARY KEY(group_id,revision_event_id));
        CREATE TABLE IF NOT EXISTS nonces(group_id TEXT NOT NULL,sender TEXT NOT NULL,nonce TEXT NOT NULL,expires REAL NOT NULL,PRIMARY KEY(group_id,sender,nonce));
        CREATE TABLE IF NOT EXISTS admin_audit(id INTEGER PRIMARY KEY AUTOINCREMENT,group_id TEXT NOT NULL,device_id TEXT NOT NULL,operation INTEGER NOT NULL,created_at REAL NOT NULL,details BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value BLOB NOT NULL);
        ''')
        self.fts = True
        try:
            self.db.execute('CREATE VIRTUAL TABLE IF NOT EXISTS event_search USING fts5(group_id UNINDEXED,event_id UNINDEXED,text,tokenize="unicode61")')
            self.db.execute("INSERT INTO event_search(event_search,rank) VALUES('secure-delete',1)")
        except sqlite3.OperationalError:
            self.fts = False
        with self.transaction():
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES('archive_schema_version',?)", (b'1',))
            if not self.db.execute("SELECT 1 FROM metadata WHERE key='cursor_key'").fetchone():
                import secrets
                self.db.execute('INSERT INTO metadata VALUES(?,?)', ('cursor_key', secrets.token_bytes(32)))
        if bytes(self.db.execute("SELECT value FROM metadata WHERE key='archive_schema_version'").fetchone()[0]) != b'1':
            raise ValueError('unsupported archive schema')
        self.cursor_key = bytes(self.db.execute("SELECT value FROM metadata WHERE key='cursor_key'").fetchone()[0])
        # Restrict newly created archive database; its parent remains deployment-owned.
        if str(database) != ':memory:':
            self.path.chmod(0o600)
            for suffix in ['-wal', '-shm']:
                sidecar = Path(str(self.path) + suffix)
                if sidecar.exists():
                    sidecar.chmod(0o600)
        self.ledger_path = None if str(database) == ':memory:' else Path(str(database) + '.erase-ledger.jsonl')
        self.reconcile_deletions()

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

    def rotate_recovery_identity(self):
        """Offline restore only: invalidate all cursors and downstream source IDs.

        A database restore affects every tenant in this store. Do not rotate on
        ordinary startup, backup, or one tenant's privacy erase.
        """
        import secrets
        with self.lock:
            key = secrets.token_bytes(32)
            with self.transaction():
                self.db.execute("UPDATE metadata SET value=? WHERE key='cursor_key'", (key,))
            self.cursor_key = key

    def group(self, group):
        self.db.execute('INSERT OR IGNORE INTO archive_groups(group_id) VALUES(?)', (group,))
        return self.db.execute('SELECT * FROM archive_groups WHERE group_id=?', (group,)).fetchone()

    def consent(self, group, device):
        row = self.db.execute('SELECT * FROM device_consents WHERE group_id=? AND device_id=?', (group, device)).fetchone()
        if row is None:
            return None
        return {'version': row['version'], 'enabled': bool(row['enabled']), 'providers': decode(row['providers']), 'readers': decode(row['readers'])}

    def high(self, group):
        return self.db.execute('SELECT COALESCE(MAX(seq),0) FROM change_log WHERE group_id=?', (group,)).fetchone()[0]

    def append_change(self, group, device, event, kind, now):
        sequence = self.high(group) + 1
        self.db.execute('INSERT INTO change_log VALUES(?,?,?,?,?,?)', (sequence, group, device, event, kind, now))
        return sequence

    def stamp(self, who):
        policy = self.group(who.group)
        # Active-set hash includes departures/idle expiry even absent membership revision.
        return hashlib.sha256(who.digest + encode(sorted(who.members)) + struct.pack('>QQ', policy['acl_version'], policy['policy_version'])).hexdigest()

    def scopes(self, who):
        allowed = {who.sender}
        for row in self.db.execute('SELECT device_id,enabled,readers FROM device_consents WHERE group_id=?', (who.group,)):
            if row['device_id'] in who.members and row['enabled'] and who.sender in decode(row['readers']):
                allowed.add(row['device_id'])
        return allowed

    def cursor(self, who, mode, position, high, filters):
        value = {'v': 1, 'group': who.group, 'reader': who.sender, 'acl': self.stamp(who), 'mode': mode, 'position': position, 'high': high, 'filters': filters, 'expires': int(self.clock()) + self.cursor_ttl}
        raw = encode(value)
        return base64.urlsafe_b64encode(raw + hmac.new(self.cursor_key, raw, hashlib.sha256).digest()).decode()

    def read_cursor(self, who, token, mode):
        if type(token) is not str or len(token) > 8192:
            fail('cursor')
        try:
            data = base64.b64decode(token, altchars=b'-_', validate=True)
        except (ValueError, UnicodeError):
            fail('cursor')
        if len(data) < 33 or not hmac.compare_digest(data[-32:], hmac.new(self.cursor_key, data[:-32], hashlib.sha256).digest()):
            fail('cursor', 403)
        value = decode(data[:-32])
        if value.get('group') != who.group or value.get('reader') != who.sender or value.get('mode') != mode:
            fail('cursor_scope', 403)
        if value['expires'] < self.clock():
            fail('cursor_expired', 409)
        if value['acl'] != self.stamp(who):
            fail('cursor_stale', 409)
        current_high = self.high(who.group)
        if value['position'] > current_high or (mode == 'query' and value['high'] > current_high):
            fail('cursor_source_rewound', 409)
        return value

    def audit(self, who, operation, details=None):
        # Only objective counts, never query strings or event bodies.
        self.db.execute('INSERT INTO admin_audit(group_id,device_id,operation,created_at,details) VALUES(?,?,?,?,?)', (who.group, who.sender, operation, self.clock(), encode(details or {})))

    def process(self, who, operation, body, nonce):
        with self.lock:
            try:
                # TTL deletion also writes the independent durable erasure ledger.
                self.expire(who.group)
                with self.transaction():
                    self.group(who.group)
                    self.db.execute('DELETE FROM nonces WHERE expires<?', (self.clock(),))
                    try:
                        self.db.execute('INSERT INTO nonces VALUES(?,?,?,?)', (who.group, who.sender, nonce, self.clock() + 600))
                    except sqlite3.IntegrityError:
                        fail('replay', 409)
                    methods = {1: self.status, 2: self.set_policy, 3: self.set_consent, 4: self.ingest, 5: self.query, 6: self.changes, 7: self.snapshot, 8: self.export, 9: self.erase, 10: self.paragraphs, 11: self.register_capture_key}
                    result = methods[operation](who, body)
                    if operation == 4:
                        # Only signature-verified, policy+consent-accepted ingest; no
                        # body or device clock is used as liveness evidence.
                        self.db.execute('INSERT INTO member_activity VALUES(?,?,?,?) ON CONFLICT(group_id,device_id) DO UPDATE SET member_key_fingerprint=excluded.member_key_fingerprint,last_seen=excluded.last_seen', (who.group, who.sender, hashlib.sha256(who.public).digest(), int(self.clock())))
                    self.audit(who, operation, {'result_count': len(result.get('events', result.get('changes', result.get('erased_event_ids', []))))})
                    # Unbounded untrusted extension values cannot turn reads into huge responses.
                    if len(encode({'version': 1, 'operation': operation, 'result': result})) > MAX_RESPONSE:
                        fail('response_size', 413)
                if operation == 9:
                    checkpoint = self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()
                    result['storage_cleanup'] = 'checkpointed' if checkpoint[0] == 0 else 'pending_checkpoint'
                return result
            except sqlite3.OperationalError as error:
                if 'full' in str(error).lower():
                    fail('archive_capacity', 507)
                fail('archive_unavailable', 503)

    def status(self, who, value):
        shape(value)
        p = self.group(who.group)
        return {'group': who.group, 'device': who.sender, 'enabled': bool(p['enabled']), 'policy_version': p['policy_version'], 'membership_revision': who.revision, 'consent': self.consent(who.group, who.sender), 'devices': self.device_inventory(who), 'limits': {'max_batch_events': MAX_BATCH, 'max_event_bytes': EVENT_LIMIT, 'max_body_bytes': BODY_LIMIT, 'retention_days': p['retention_days'], 'max_group_bytes': p['max_group_bytes']}}

    def device_inventory(self, who):
        """Current group only. Hardware is self-reported, never inferred from IDs.

        A member list does not grant access to another member's archive metadata.
        No event text, serials, hostnames, or departed-device history is returned.
        """
        readable = self.scopes(who)
        devices = []
        for device in sorted(who.members):
            item = {'device_id': device, 'archive_readable': device in readable, 'metadata': None}
            if device in readable:
                row = self.db.execute('SELECT event_json FROM events WHERE group_id=? AND device_id=? ORDER BY change_seq DESC LIMIT 1', (who.group, device)).fetchone()
                if row:
                    event = decode(row['event_json'])
                    metadata = (event.get('extensions') or {}).get('org.linghe.device.v1')
                    if isinstance(metadata, dict):
                        item['metadata'] = {k: v for k, v in metadata.items() if k in {'platform', 'brand', 'manufacturer', 'model', 'os_version', 'architecture', 'device_type'} and type(v) is str and 0 < len(v.encode('utf-8')) <= 128 and not any(ord(c) < 32 for c in v)}
                        item['metadata_provenance'] = 'device_self_reported'
            devices.append(item)
        return devices

    def set_policy(self, who, value):
        shape(value, ['expected_version', 'enabled', 'retention_days', 'max_group_bytes'])
        if who.permissions != 3:
            fail('manage_permission', 403)
        previous = self.group(who.group)
        if number(value['expected_version']) != previous['policy_version']:
            fail('policy_conflict', 409)
        enabled = boolean(value['enabled'])
        days = number(value['retention_days'], 1, 3650)
        quota = number(value['max_group_bytes'], 1048576, 1073741824)
        version = previous['policy_version'] + 1
        self.db.execute('UPDATE archive_groups SET policy_version=?,enabled=?,retention_days=?,max_group_bytes=?,acl_version=acl_version+1 WHERE group_id=?', (version, int(enabled), days, quota, who.group))
        if not enabled:
            # Closing a group revokes provider grants, not just the current HTTP gate.
            # Reopening cannot silently resurrect pre-close queues or consents.
            self.db.execute('UPDATE device_consents SET version=version+1,enabled=0 WHERE group_id=?', (who.group,))
            self.db.execute('DELETE FROM capture_keys WHERE group_id=?', (who.group,))
        return {'policy_version': version, 'enabled': enabled, 'retention_days': days, 'max_group_bytes': quota}

    def set_consent(self, who, value):
        shape(value, ['expected_version', 'enabled', 'providers'], ['readers'])
        previous = self.consent(who.group, who.sender)
        if number(value['expected_version']) != (previous['version'] if previous else 0):
            fail('consent_conflict', 409)
        enabled = boolean(value['enabled'])
        providers = value['providers']
        if type(providers) is not list or not 1 <= len(providers) <= 32 or any(type(p) is not str or not ID_PATTERN.fullmatch(p) for p in providers) or len(set(providers)) != len(providers):
            fail('providers')
        readers = value.get('readers', [who.sender])
        if type(readers) is not list or len(readers) > 64:
            fail('readers')
        readers = [uid(r) for r in readers]
        if len(set(readers)) != len(readers) or any(r not in who.members for r in readers):
            fail('reader_member', 403)
        version = (previous['version'] if previous else 0) + 1
        self.db.execute('INSERT INTO device_consents VALUES(?,?,?,?,?,?) ON CONFLICT(group_id,device_id) DO UPDATE SET version=excluded.version,enabled=excluded.enabled,providers=excluded.providers,readers=excluded.readers', (who.group, who.sender, version, int(enabled), encode(providers), encode(readers)))
        self.db.execute('UPDATE archive_groups SET acl_version=acl_version+1 WHERE group_id=?', (who.group,))
        self.db.execute('DELETE FROM capture_keys WHERE group_id=? AND device_id=?', (who.group, who.sender))
        consent = {'version': version, 'enabled': enabled, 'providers': providers, 'readers': readers}
        return {'consent_version': version, 'consent': consent}

    def register_capture_key(self, who, value):
        shape(value, ['expected_consent_version', 'public_key'])
        consent = self.consent(who.group, who.sender)
        if not consent or not consent['enabled']:
            fail('consent_disabled', 403)
        if not self.group(who.group)['enabled']:
            fail('archive_disabled', 403)
        if number(value['expected_consent_version'], 1) != consent['version']:
            fail('consent_stale', 409)
        public = unb64(value['public_key'], 32, 32)
        self.db.execute('INSERT INTO capture_keys VALUES(?,?,?,?,?) ON CONFLICT(group_id,device_id) DO UPDATE SET public_key=excluded.public_key,member_key_fingerprint=excluded.member_key_fingerprint,consent_version=excluded.consent_version', (who.group, who.sender, public, hashlib.sha256(who.public).digest(), consent['version']))
        return {'registered': True, 'consent_version': consent['version']}

    def verify_capture_signature(self, who, operation, signature, canonical):
        # Restricted extension signer can only check own status and upload own
        # events. Membership, management, reads and new delegation require primary.
        if operation not in {1, 4}:
            return False
        with self.lock:
            consent = self.consent(who.group, who.sender)
            row = self.db.execute('SELECT * FROM capture_keys WHERE group_id=? AND device_id=?', (who.group, who.sender)).fetchone()
            policy = self.db.execute('SELECT enabled FROM archive_groups WHERE group_id=?', (who.group,)).fetchone()
            if not row or not consent or not consent['enabled'] or not policy or not policy['enabled'] or row['consent_version'] != consent['version'] or row['member_key_fingerprint'] != hashlib.sha256(who.public).digest():
                return False
            try:
                Ed25519PublicKey.from_public_bytes(bytes(row['public_key'])).verify(signature, canonical)
                return True
            except (InvalidSignature, ValueError):
                return False

    def validate_event(self, who, event, consent):
        shape(event, REQUIRED, OPTIONAL)
        if number(event['schema_version'], 1, 1) != 1:
            fail('schema_version')
        event_id = uid(event['event_id'])
        if uid(event['device_group']) != who.group or uid(event['device_id']) != who.sender:
            fail('event_identity', 403)
        install = uid(event['installation_id'])
        seq = number(event['device_seq'], 1)
        if number(event['consent_version'], 1) != consent['version']:
            fail('consent_stale', 409)
        if event['provider_id'] not in consent['providers']:
            fail('provider_not_allowed', 403)
        if type(event['event_type']) is not str or event['event_type'] not in TYPES:
            fail('event_type')
        observed = timestamp(event['observed_at'])
        # Old offline data is explicit expired, never silently kept beyond retention.
        p = self.group(who.group)
        if observed < self.clock() - p['retention_days'] * 86400:
            fail('event_expired', 409)
        if observed > self.clock() + 86400:
            fail('event_clock', 400)
        shape(event['content'], ['text'])
        if type(event['content']['text']) is not str:
            fail('text')
        if event['event_type'] == 'coverage_gap' and event['content']['text']:
            fail('gap_text')
        for field in ['timezone_id', 'input_session', 'editor_epoch', 'span_id', 'source_kind', 'source_app', 'document_id', 'delivery_state', 'commit_confirmation', 'sensitivity', 'time_quality']:
            if field in event and event[field] is not None and (type(event[field]) is not str or len(event[field]) > 256):
                fail('event_metadata')
        if 'utc_offset_minutes' in event:
            number(event['utc_offset_minutes'], -1440, 1440)
        if 'links' in event and (type(event['links']) is not list or len(event['links']) > 64):
            fail('event_links')
        if 'extensions' in event and (type(event['extensions']) is not dict or len(event['extensions']) > 32):
            fail('extensions')
        diagnostic_error = validate_decision_extensions(event)
        if diagnostic_error:
            fail(diagnostic_error)
        if 'edit_op' in event and event['edit_op'] is not None:
            if type(event['edit_op']) is not dict or type(event['edit_op'].get('kind')) is not str or event['edit_op'].get('kind') not in {'insert', 'replace', 'delete', 'unknown'}:
                fail('edit_op')
        raw = encode(event)
        if len(raw) > EVENT_LIMIT:
            fail('event_size', 413)
        return event_id, install, seq, observed, raw, hashlib.sha256(raw).hexdigest()

    def ingest(self, who, value):
        shape(value, ['batch_id', 'events'])
        batch_id = uid(value['batch_id'])
        events = value['events']
        if type(events) is not list or not 1 <= len(events) <= MAX_BATCH:
            fail('batch_size')
        policy = self.group(who.group)
        consent = self.consent(who.group, who.sender)
        if not policy['enabled']:
            fail('archive_disabled', 403)
        if not consent or not consent['enabled']:
            fail('consent_disabled', 403)
        batch_hash = hashlib.sha256(encode(value)).hexdigest()
        receipt = self.db.execute('SELECT body_hash FROM ingest_receipts WHERE group_id=? AND device_id=? AND batch_id=?', (who.group, who.sender, batch_id)).fetchone()
        if receipt and receipt[0] != batch_hash:
            fail('batch_conflict', 409)
        accepted, duplicates, installations, batch_seen = [], [], set(), set()
        now = self.clock()
        for event in events:
            event_id, install, seq, observed, raw, digest = self.validate_event(who, event, consent)
            if event_id in batch_seen:
                fail('batch_event_duplicate', 409)
            batch_seen.add(event_id)
            installations.add(install)
            if self.db.execute('SELECT 1 FROM deletion_tombstones WHERE group_id=? AND (event_id=? OR (device_id=? AND installation_id=? AND device_seq=?))', (who.group, event_id, who.sender, install, seq)).fetchone():
                fail('event_erased', 409)
            existing = self.db.execute('SELECT device_id,content_hash FROM events WHERE group_id=? AND event_id=?', (who.group, event_id)).fetchone()
            if existing:
                if existing['device_id'] != who.sender or existing['content_hash'] != digest:
                    fail('event_conflict', 409)
                duplicates.append(event_id)
                continue
            if self.db.execute('SELECT 1 FROM events WHERE group_id=? AND device_id=? AND installation_id=? AND device_seq=?', (who.group, who.sender, install, seq)).fetchone():
                fail('sequence_conflict', 409)
            total = self.db.execute('SELECT COALESCE(SUM(size_bytes),0),COUNT(*) FROM events WHERE group_id=?', (who.group,)).fetchone()
            if total[0] + len(raw) > policy['max_group_bytes'] or total[1] >= 100000:
                fail('group_capacity', 507)
            target = event.get('edit_op') or {}
            target_id = target.get('target_event_id')
            if target_id is not None:
                target_id = uid(target_id)
                row = self.db.execute('SELECT device_id,event_json FROM events WHERE group_id=? AND event_id=?', (who.group, target_id)).fetchone()
                if not row or row['device_id'] != who.sender:
                    fail('revision_target', 403)
                prior = decode(row['event_json'])
                if not event.get('input_session') or event.get('input_session') != prior.get('input_session') or not event.get('editor_epoch') or event.get('editor_epoch') != prior.get('editor_epoch'):
                    fail('revision_scope', 409)
                self.db.execute('INSERT INTO event_revisions VALUES(?,?,?)', (who.group, target_id, event_id))
            change = self.append_change(who.group, who.sender, event_id, 'upsert', now)
            self.db.execute('INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)', (who.group, event_id, who.sender, install, seq, event['provider_id'], event['event_type'], observed, now, change, digest, raw, len(raw)))
            if self.fts:
                self.db.execute('INSERT INTO event_search VALUES(?,?,?)', (who.group, event_id, event['content']['text']))
            accepted.append(event_id)
        self.db.execute('INSERT OR IGNORE INTO ingest_receipts VALUES(?,?,?,?,?,?)', (who.group, who.sender, batch_id, batch_hash, encode(sorted(batch_seen)), now))
        ranges = []
        for install in sorted(installations):
            # Tombstoned sequences remain acknowledged, but their content can never revive.
            seqs = [r[0] for r in self.db.execute('SELECT device_seq FROM events WHERE group_id=? AND device_id=? AND installation_id=? UNION SELECT device_seq FROM deletion_tombstones WHERE group_id=? AND device_id=? AND installation_id=? ORDER BY 1', (who.group, who.sender, install, who.group, who.sender, install))]
            contiguous = 0
            for s in seqs:
                if s != contiguous + 1:
                    break
                contiguous = s
            # Ranges acknowledge this batch only (<=128), whereas contiguous is
            # cumulative. This remains bounded even after 100k sparse arrivals.
            batch_seqs = sorted({event['device_seq'] for event in events if uid(event['installation_id']) == install})
            spans = []
            for s in batch_seqs:
                if spans and s == spans[-1][1] + 1:
                    spans[-1][1] = s
                else:
                    spans.append([s, s])
            ranges.append({'installation_id': install, 'ranges': spans, 'contiguous_through': contiguous})
        return {'batch_id': batch_id, 'accepted_event_ids': accepted, 'duplicate_event_ids': duplicates, 'received_ranges': ranges, 'server_received_at': iso(now), 'high_watermark': self.high(who.group)}

    def filters(self, value):
        if value is None:
            return {}
        shape(value, [], ['device_id', 'event_type', 'provider_id', 'observed_from', 'observed_to'])
        result = dict(value)
        if 'device_id' in value:
            result['device_id'] = uid(value['device_id'])
        if 'event_type' in value and (type(value['event_type']) is not str or value['event_type'] not in TYPES):
            fail('event_type')
        if 'provider_id' in value and (type(value['provider_id']) is not str or not ID_PATTERN.fullmatch(value['provider_id'])):
            fail('provider')
        for key in ['observed_from', 'observed_to']:
            if key in value:
                timestamp(value[key])
        return result

    def stored(self, row):
        event = decode(row['event_json'])
        event.update(server_received_at=iso(row['received_at']), change_seq=row['change_seq'], content_hash=row['content_hash'])
        return event

    def _page(self, who, value):
        shape(value, [], ['limit', 'cursor', 'filters'])
        limit = number(value.get('limit', 50), 1, 128)
        filters = self.filters(value.get('filters'))
        if value.get('cursor'):
            c = self.read_cursor(who, value['cursor'], 'query')
            if 'filters' in value and filters != c['filters']:
                fail('cursor_filters', 409)
            filters, position, high = c['filters'], c['position'], c['high']
        else:
            position, high = 0, self.high(who.group)
        scopes = sorted(self.scopes(who))
        clauses = ['group_id=?', 'device_id IN (' + ','.join('?' * len(scopes)) + ')', 'change_seq>?', 'change_seq<=?']
        args = [who.group] + scopes + [position, high]
        for key in ['device_id', 'event_type', 'provider_id']:
            if key in filters:
                clauses.append(key + '=?'); args.append(filters[key])
        for key, op in [('observed_from', '>='), ('observed_to', '<')]:
            if key in filters:
                clauses.append('observed_at' + op + '?'); args.append(timestamp(filters[key]))
        rows = self.db.execute('SELECT * FROM events WHERE ' + ' AND '.join(clauses) + ' ORDER BY change_seq LIMIT ?', args + [limit + 1]).fetchall()
        selected, size = [], 0
        for row in rows[:limit]:
            # Escape-heavy JSONL costs more; reserve enough for either JSON export encoding.
            if selected and size + row['size_bytes'] > 280000:
                break
            selected.append(row); size += row['size_bytes']
        more = len(selected) < len(rows)
        next_cursor = self.cursor(who, 'query', selected[-1]['change_seq'], high, filters) if selected and more else None
        return selected, next_cursor, high, filters

    def query(self, who, value):
        rows, cursor, high, _ = self._page(who, value)
        return {'events': [self.stored(row) for row in rows], 'next_cursor': cursor, 'high_watermark': high}

    def snapshot(self, who, value):
        result = self.query(who, value)
        result.update(snapshot=True, changes_cursor=self.cursor(who, 'changes', result['high_watermark'], 0, {}))
        return result

    def changes(self, who, value):
        shape(value, [], ['cursor', 'limit'])
        limit = number(value.get('limit', 50), 1, 128)
        position = self.read_cursor(who, value['cursor'], 'changes')['position'] if value.get('cursor') else 0
        high = self.high(who.group)
        scopes = sorted(self.scopes(who))
        rows = self.db.execute('SELECT * FROM change_log WHERE group_id=? AND device_id IN (' + ','.join('?' * len(scopes)) + ') AND seq>? AND seq<=? ORDER BY seq LIMIT ?', [who.group] + scopes + [position, high, limit + 1]).fetchall()
        changes, size = [], 0
        consumed = position
        for row in rows[:limit]:
            change = {'change_seq': row['seq'], 'kind': row['kind'], 'event_id': row['event_id'], 'device_id': row['device_id']}
            if row['kind'] == 'upsert':
                event = self.db.execute('SELECT * FROM events WHERE group_id=? AND event_id=?', (who.group, row['event_id'])).fetchone()
                if event is None:
                    # Never expose deleted body, even for older upsert log records.
                    change['kind'] = 'erase'
                else:
                    change['event'] = self.stored(event)
            if change['kind'] == 'erase':
                change['erase_reason'] = self.erase_reason(who.group, row['event_id'])
            cost = len(encode(change))
            if changes and size + cost > 600000:
                break
            changes.append(change); size += cost; consumed = row['seq']
        more = len(changes) < len(rows)
        if not more:
            consumed = high  # Skips invisible entries while current ACL stamp remains fixed.
        return {'changes': changes, 'next_cursor': self.cursor(who, 'changes', consumed, 0, {}), 'high_watermark': high, 'has_more': more}

    def export(self, who, value):
        rows, cursor, high, _ = self._page(who, value)
        lines = [encode({'record_type': 'manifest', 'schema_version': 1, 'group': who.group, 'high_watermark': high})]
        lines.extend(encode({'record_type': 'event', 'event': self.stored(row)}) for row in rows)
        return {'format': 'jsonl', 'jsonl': b'\n'.join(lines).decode('utf-8') + '\n', 'next_cursor': cursor, 'high_watermark': high}

    def erase_reason(self, group, event):
        row = self.db.execute('SELECT reason FROM erasure_reasons WHERE group_id=? AND event_id=?', (group, event)).fetchone()
        return row['reason'] if row else 'unknown'

    def ledger(self, rows, reason):
        if not rows or self.ledger_path is None:
            return
        # A durable intent is fsynced BEFORE SQL deletion; replay is idempotent.
        import os
        entries = []
        for row in rows:
            value = {key: row[key] for key in ['group_id', 'event_id', 'device_id', 'installation_id', 'device_seq']}
            value['erase_reason'] = reason
            base = self.db.execute('SELECT base_event_id FROM event_revisions WHERE group_id=? AND revision_event_id=? UNION SELECT base_event_id FROM erasure_revision_links WHERE group_id=? AND revision_event_id=?', (row['group_id'], row['event_id'], row['group_id'], row['event_id'])).fetchone()
            if base:
                value['base_event_id'] = base[0]
            entries.append(encode(value) + b'\n')
        raw = b''.join(entries)
        if self.ledger_path.exists() and self.ledger_path.stat().st_size + len(raw) > MAX_LEDGER_BYTES:
            fail('erasure_ledger_capacity', 507)
        created = not self.ledger_path.exists()
        descriptor = os.open(self.ledger_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            view = memoryview(raw)
            while view:
                view = view[os.write(descriptor, view):]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if created:
            directory = os.open(self.ledger_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)

    def _delete(self, rows, *, reason='unknown', write_ledger=True):
        if reason not in ERASE_REASONS:
            raise ValueError('invalid erasure reason')
        if write_ledger:
            self.ledger(rows, reason)
        erased = []
        for row in rows:
            now = self.clock()
            inserted = self.db.execute('INSERT OR IGNORE INTO deletion_tombstones VALUES(?,?,?,?,?,?)', (row['group_id'], row['event_id'], row['device_id'], row['installation_id'], row['device_seq'], now)).rowcount
            previous_reason = self.erase_reason(row['group_id'], row['event_id'])
            effective_reason = max((previous_reason, reason), key=ERASE_REASONS.__getitem__)
            self.db.execute('INSERT INTO erasure_reasons VALUES(?,?,?) ON CONFLICT(group_id,event_id) DO UPDATE SET reason=excluded.reason', (row['group_id'], row['event_id'], effective_reason))
            removed = self.db.execute('DELETE FROM events WHERE group_id=? AND event_id=?', (row['group_id'], row['event_id'])).rowcount
            if self.fts:
                self.db.execute('DELETE FROM event_search WHERE group_id=? AND event_id=?', (row['group_id'], row['event_id']))
            self.db.execute('INSERT OR IGNORE INTO erasure_revision_links SELECT * FROM event_revisions WHERE group_id=? AND (base_event_id=? OR revision_event_id=?)', (row['group_id'], row['event_id'], row['event_id']))
            self.db.execute('DELETE FROM event_revisions WHERE group_id=? AND (base_event_id=? OR revision_event_id=?)', (row['group_id'], row['event_id'], row['event_id']))
            if removed or inserted or previous_reason != effective_reason:
                self.append_change(row['group_id'], row['device_id'], row['event_id'], 'erase', now)
            erased.append(row['event_id'])
        return erased

    def deletion_rows(self, group, ids):
        pending, seen, rows = list(ids), set(), []
        while pending:
            event_id = pending.pop()
            if event_id in seen:
                continue
            seen.add(event_id)
            row = self.db.execute('SELECT * FROM events WHERE group_id=? AND event_id=?', (group, event_id)).fetchone()
            if row is None:
                row = self.db.execute('SELECT * FROM deletion_tombstones WHERE group_id=? AND event_id=?', (group, event_id)).fetchone()
            if row:
                rows.append(row)
            pending.extend(r[0] for r in self.db.execute('SELECT revision_event_id FROM event_revisions WHERE group_id=? AND base_event_id=? UNION SELECT revision_event_id FROM erasure_revision_links WHERE group_id=? AND base_event_id=?', (group, event_id, group, event_id)))
        return rows

    def erase(self, who, value):
        shape(value, ['event_ids'])
        if type(value['event_ids']) is not list or not 1 <= len(value['event_ids']) <= 128:
            fail('erase_size')
        ids = [uid(e) for e in value['event_ids']]
        # Resolve all authorization BEFORE ledger; no privacy action on denied request.
        for event_id in ids:
            row = self.db.execute('SELECT device_id FROM events WHERE group_id=? AND event_id=? UNION SELECT device_id FROM deletion_tombstones WHERE group_id=? AND event_id=?', (who.group, event_id, who.group, event_id)).fetchone()
            if not row or row[0] != who.sender:
                fail('erase_owner', 403)
        rows = self.deletion_rows(who.group, ids)
        # A repeated request is idempotent, but an expired tombstone must be
        # upgraded and emitted again so long-lived archives erase their copy.
        rows = [row for row in rows if self.erase_reason(row['group_id'], row['event_id']) != 'user_erase']
        erased = self._delete(rows, reason='user_erase')
        erased.extend(event_id for event_id in ids if event_id not in erased)
        return {'erased_event_ids': erased, 'high_watermark': self.high(who.group)}

    def reconcile_deletions(self):
        if self.ledger_path is None or not self.ledger_path.exists():
            return
        # Missing/newer external deletion ledger after restore is an operator error;
        # README requires copying latest ledger first. Corrupt/torn ledger fails shut.
        with self.lock, self.transaction():
            with self.ledger_path.open('rb') as stream:
                for line in stream:
                    if len(line) > 2048 or not line.endswith(b'\n'):
                        raise ValueError('erasure ledger corrupt; repair before serving')
                    value = decode(line)
                    shape(value, ['group_id', 'event_id', 'device_id', 'installation_id', 'device_seq'], ['erase_reason', 'base_event_id'])
                    for field in ['group_id', 'event_id', 'device_id', 'installation_id']:
                        uid(value[field])
                    number(value['device_seq'], 1)
                    reason = value.get('erase_reason', 'unknown')
                    if type(reason) is not str or reason not in ERASE_REASONS:
                        raise ValueError('invalid erasure reason in ledger')
                    if 'base_event_id' in value:
                        base = uid(value['base_event_id'])
                        self.db.execute('INSERT OR IGNORE INTO erasure_revision_links VALUES(?,?,?)', (value['group_id'], base, value['event_id']))
                    rows = self.deletion_rows(value['group_id'], [value['event_id']])
                    # If event absent (snapshot predates creation), tombstone still prevents upload.
                    if not any(row['event_id'] == value['event_id'] for row in rows):
                        rows.append(value)
                    self._delete(rows, reason=reason, write_ledger=False)

    def expire(self, group):
        p = self.db.execute('SELECT retention_days FROM archive_groups WHERE group_id=?', (group,)).fetchone()
        if p is None:
            return
        ids = [r[0] for r in self.db.execute('SELECT event_id FROM events WHERE group_id=? AND observed_at<?', (group, self.clock() - p[0] * 86400))]
        if ids:
            with self.transaction():
                self._delete(self.deletion_rows(group, ids), reason='retention_expire')
            self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        # Keep protocol metadata bounded without weakening permanent erase tombstones.
        self.db.execute('DELETE FROM ingest_receipts WHERE created_at<?', (self.clock() - 7 * 86400,))
        self.db.execute('DELETE FROM admin_audit WHERE created_at<?', (self.clock() - 90 * 86400,))

    def paragraphs(self, who, value):
        rows, cursor, high, _ = self._page(who, value)
        paragraphs = []
        prior_event_type = None
        for row in rows:
            event = self.stored(row)
            # No final-document claim: source APIs often do not observe mouse edits.
            reliable = event.get('input_session') and event.get('editor_epoch') and event['event_type'] == 'input_commit'
            edit = event.get('edit_op') or {}
            fragment = {'paragraph_id': event['event_id'], 'device_id': row['device_id'], 'input_session': event.get('input_session'), 'editor_epoch': event.get('editor_epoch'), 'text': event['content']['text'], 'source_event_ids': [event['event_id']], 'rule_version': 1, 'revision': row['change_seq'], 'complete': False, 'view_kind': 'fragment_sequence', 'coverage': 'observed_fragments_only'}
            previous = paragraphs[-1] if paragraphs else None
            # Append only if producer explicitly states append to predecessor span.
            anchor = edit.get('anchor')
            if reliable and prior_event_type == 'input_commit' and edit.get('kind') == 'insert' and type(anchor) is dict and anchor.get('kind') == 'after_event' and previous and type(anchor.get('event_id')) is str and anchor['event_id'].upper() == previous['source_event_ids'][-1].upper() and previous['device_id'] == row['device_id'] and previous['input_session'] == event['input_session'] and previous['editor_epoch'] == event['editor_epoch']:
                previous['text'] += event['content']['text']
                previous['source_event_ids'].append(event['event_id'])
                previous['revision'] = row['change_seq']
                previous['view_kind'] = 'anchored_replay'
                previous['coverage'] = 'producer_anchored_fragments_only'
            else:
                paragraphs.append(fragment)
            prior_event_type = event['event_type']
        return {'paragraphs': paragraphs, 'next_cursor': cursor, 'high_watermark': high}

    def backup(self, destination):
        """Consistent SQL snapshot. Latest deletion ledger is a separate restore input."""
        with self.lock:
            target = sqlite3.connect(str(destination))
            try:
                self.db.backup(target)
            finally:
                target.close()
            Path(destination).chmod(0o600)


class ArchiveApplication:
    def __init__(self, store, authority, *, clock=time.time):
        self.store, self.authority, self.clock = store, authority, clock
        self.rates = {}
        self.rate_lock = threading.Lock()

    def capabilities(self):
        return {'protocol': 'private-input-activity', 'version': 1, 'storage': 'server_plaintext', 'default_enabled': False, 'max_wrapper_bytes': WRAPPER_LIMIT, 'max_body_bytes': BODY_LIMIT, 'max_batch_events': MAX_BATCH, 'max_event_bytes': EVENT_LIMIT, 'operations': list(range(1, 12)), 'event_types': sorted(TYPES), 'capture_scope': 'provider_observed_only', 'requires_group_policy_and_device_consent': True}

    def dispatch(self, raw):
        if len(raw) > WRAPPER_LIMIT:
            fail('request_size', 413)
        envelope = decode(raw)
        shape(envelope, ['version', 'group', 'sender', 'nonce', 'issuedAt', 'operation', 'body', 'signature'])
        number(envelope['version'], 1, 1)
        group, sender, nonce = (uid(envelope[k]) for k in ['group', 'sender', 'nonce'])
        number(envelope['issuedAt'], 0, (1 << 64) - 1)
        if abs(self.clock() - envelope['issuedAt']) > 300:
            fail('request_clock', 401)
        operation = number(envelope['operation'], 1, 11)
        body = unb64(envelope['body'])
        signature = unb64(envelope['signature'], 64, 64)
        who = self.authority.resolve(group, sender, self.clock())
        capture_delegate = False
        try:
            Ed25519PublicKey.from_public_bytes(who.public).verify(signature, request_canonical(envelope, body))
        except (InvalidSignature, ValueError):
            if not self.store.verify_capture_signature(who, operation, signature, request_canonical(envelope, body)):
                fail('signature', 401)
            capture_delegate = True
        with self.rate_lock:
            now = self.clock()
            self.rates = {k: v for k, v in self.rates.items() if v[0] > now - 60}
            key = (group, sender)
            start, count = self.rates.get(key, (now, 0))
            if count >= 240 or len(self.rates) >= 10000 and key not in self.rates:
                fail('rate_limit', 429)
            self.rates[key] = (start, count + 1)
        result = self.store.process(who, operation, decode(body), nonce)
        if capture_delegate and operation == 1:
            result.pop("devices", None)
        return {'version': 1, 'operation': operation, 'result': result}

    def __call__(self, environ, start_response):
        status = 200
        try:
            method, path = environ.get('REQUEST_METHOD'), environ.get('PATH_INFO')
            if method == 'GET' and path == '/v1/activity/capabilities':
                response = self.capabilities()
            elif method == 'GET' and path == '/healthz':
                with self.store.lock:
                    self.store.db.execute('SELECT 1').fetchone()
                response = {'service': 'private-input-activity', 'ready': True}
            elif method == 'POST' and path == '/v1/activity/rpc':
                length = environ.get('CONTENT_LENGTH', '')
                if not length.isdecimal() or int(length) > WRAPPER_LIMIT:
                    fail('request_size', 413)
                if environ.get('CONTENT_TYPE', '').split(';', 1)[0].strip().lower() != 'application/json':
                    fail('content_type', 415)
                raw = environ['wsgi.input'].read(int(length))
                if len(raw) != int(length):
                    fail('request_length')
                response = self.dispatch(raw)
            else:
                fail('not_found', 404)
        except ArchiveError as error:
            status, response = error.status, {'version': 1, 'error': error.code}
        except (sqlite3.Error, OSError):
            status, response = 503, {'version': 1, 'error': 'archive_unavailable'}
        except Exception:
            # Fail closed without emitting request/body/traceback into shared logs.
            status, response = 500, {'version': 1, 'error': 'internal'}
        from http import HTTPStatus
        raw = encode(response)
        start_response(str(status) + ' ' + HTTPStatus(status).phrase, [('Content-Type', 'application/json; charset=utf-8'), ('Content-Length', str(len(raw))), ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')])
        return [raw]
