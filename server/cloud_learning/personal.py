"""Personal entries (word/phrase) as server-held records: one authority for all devices.

Same Lamport/tombstone record schema as the clients' PersonalLexicon: a record wins
by higher (sequence, device); at equal sequence a deletion wins; an equal revision
must carry the identical record. Records are never physically removed here.
"""
import re
import unicodedata
from activity_archive.service import decode, encode, fail, number, shape, uid

MAX_BATCH = 256
MAX_GROUP_RECORDS = 4000
MAX_PULL = 256
TRIGGER = re.compile(r'[a-z]+(?: [a-z]+)*')


def initialize(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS cl_personal(group_id TEXT,generation INTEGER,record_id TEXT,record_json BLOB,sequence INTEGER,device TEXT,deleted INTEGER,version INTEGER,PRIMARY KEY(group_id,generation,record_id));
    CREATE INDEX IF NOT EXISTS cl_personal_version ON cl_personal(group_id,generation,version);
    CREATE TABLE IF NOT EXISTS cl_personal_meta(group_id TEXT,generation INTEGER,version INTEGER,PRIMARY KEY(group_id,generation));
    ''')


def revision(value):
    shape(value, ('sequence', 'device'))
    number(value['sequence'], 1, (1 << 64) - 1); uid(value['device'])
    return value


def validate(record):
    """Validates and returns the record exactly as sent; the DB key is the normalized id."""
    shape(record, ('id', 'entry', 'deleted', 'revision', 'created'))
    rid = uid(record['id'])
    entry = record['entry']; shape(entry, ('id', 'kind', 'text', 'trigger'))
    if uid(entry['id']) != rid: fail('personal_id')
    kind, text, trigger = entry['kind'], entry['text'], entry['trigger']
    if kind not in ('word', 'phrase') or type(text) is not str or type(trigger) is not str: fail('personal_entry')
    if not text.strip() or len(text.encode('utf-8')) > 2048: fail('personal_text')
    if any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs') and c not in '\n\t' for c in text): fail('personal_text')
    if not TRIGGER.fullmatch(trigger) or len(trigger.encode('utf-8')) > 192: fail('personal_trigger')
    parts = trigger.split(' ')
    if kind == 'word' and ('\n' in text or '\t' in text or len(parts) > 32 or any(len(p) > 8 for p in parts)): fail('personal_entry')
    if kind == 'phrase' and (len(parts) != 1 or not 2 <= len(trigger) <= 16): fail('personal_trigger')
    if type(record['deleted']) is not bool: fail('boolean')
    rev, created = revision(record['revision']), revision(record['created'])
    if created['sequence'] > rev['sequence']: fail('personal_revision')
    return rid, record


def wins(old, new):
    """True when `new` should replace `old` (clients' PersonalLexicon.combine)."""
    a, b = (old['revision']['sequence'], uid(old['revision']['device'])), (new['revision']['sequence'], uid(new['revision']['device']))
    if a == b:
        if encode(old) != encode(new): fail('personal_revision_conflict', 409)
        return False
    if a[0] == b[0] and old['deleted'] != new['deleted']: return new['deleted']
    return b > a


def scope(store, who, body, keys):
    shape(body, keys)
    group, consent = store.require_enabled(who)
    generation = number(body['generation'])
    if generation != group['generation']: fail('generation_stale', 409)
    if number(body['consent_version']) != consent['version'] or uid(body['installation_id']) != consent['installation_id']: fail('consent_stale', 409)
    return generation


def current_version(store, gid, generation):
    row = store.db.execute('SELECT version FROM cl_personal_meta WHERE group_id=? AND generation=?', (gid, generation)).fetchone()
    return row['version'] if row else 0


def put(store, who, body):
    generation = scope(store, who, body, ('generation', 'consent_version', 'installation_id', 'records'))
    records = body['records']
    if type(records) is not list or len(records) > MAX_BATCH: fail('batch_size', 413)
    incoming = [validate(r) for r in records]
    if len({rid for rid, _ in incoming}) != len(incoming): fail('personal_duplicate')
    gid = who.group; version = current_version(store, gid, generation); applied = 0
    for rid, record in incoming:
        row = store.db.execute('SELECT record_json FROM cl_personal WHERE group_id=? AND generation=? AND record_id=?', (gid, generation, rid)).fetchone()
        if row is None:
            total = store.db.execute('SELECT COUNT(*) FROM cl_personal WHERE group_id=? AND generation=?', (gid, generation)).fetchone()[0]
            if total >= MAX_GROUP_RECORDS: fail('personal_capacity', 413)
        elif not wins(store_decode(row['record_json']), record):
            continue
        version += 1; applied += 1
        store.db.execute('INSERT OR REPLACE INTO cl_personal VALUES(?,?,?,?,?,?,?,?)',
                         (gid, generation, rid, encode(record), record['revision']['sequence'], uid(record['revision']['device']), int(record['deleted']), version))
    if applied:
        store.db.execute('INSERT OR REPLACE INTO cl_personal_meta VALUES(?,?,?)', (gid, generation, version))
    return {'accepted': True, 'applied': applied, 'version': version}


def pull(store, who, body):
    generation = scope(store, who, body, ('generation', 'consent_version', 'installation_id', 'after_version', 'limit'))
    after, limit = number(body['after_version']), number(body['limit'], 1, MAX_PULL)
    rows = store.db.execute('SELECT record_json,version FROM cl_personal WHERE group_id=? AND generation=? AND version>? ORDER BY version LIMIT ?',
                            (who.group, generation, after, limit + 1)).fetchall()
    page = rows[:limit]
    return {'records': [store_decode(r['record_json']) for r in page], 'next_version': page[-1]['version'] if page else after,
            'has_more': len(rows) > limit, 'version': current_version(store, who.group, generation)}


def store_decode(raw):
    return decode(bytes(raw))
