"""Native MAX-counter components; explicit cloud consent, no archive training."""
import hashlib
import math
from .authority import fingerprint
from activity_archive.service import decode, encode, fail, number, shape, uid

MAX_RECORDS = 128
MAX_TERMS = 5000
MAX_COMPONENT_ROWS = 64000
MAX_SCORE = 200000
HALF_LIFE = 14 * 86400


def initialize(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS cl_producers(group_id TEXT,generation INTEGER,producer_id TEXT,device_id TEXT,installation_id TEXT,consent_version INTEGER,fingerprint TEXT,revision INTEGER,digest TEXT,PRIMARY KEY(group_id,generation,producer_id));
    CREATE TABLE IF NOT EXISTS cl_components(group_id TEXT,generation INTEGER,producer_id TEXT,reading TEXT,text TEXT,record_json BLOB,score REAL,decayed_at INTEGER,undated_count INTEGER,PRIMARY KEY(group_id,generation,producer_id,reading,text));
    CREATE TABLE IF NOT EXISTS cl_publications(group_id TEXT,generation INTEGER,producer_id TEXT,publication_id TEXT,body_hash TEXT,receipt BLOB,PRIMARY KEY(group_id,generation,producer_id,publication_id));
    ''')
    columns = {row[1] for row in db.execute('PRAGMA table_info(cl_versions)')}
    if 'producer_watermarks' not in columns:
        db.execute("ALTER TABLE cl_versions ADD COLUMN producer_watermarks BLOB NOT NULL DEFAULT '[]'")


def component_digest(producer, records):
    return hashlib.sha256(encode({'producer_id': producer, 'records': sorted(records, key=lambda x: (x['reading'], x['text']))})).hexdigest()


def validate(store, record, producer):
    shape(record, ('reading', 'text', 'generation', 'deleted', 'counts', 'pinned', 'pinVersion'))
    store.term_key({'reading': record['reading'], 'text': record['text'], 'layout': 'pinyin26'})
    number(record['generation'])
    if type(record['deleted']) is not bool or type(record['pinned']) is not bool: fail('boolean')
    counts = record['counts']
    if type(counts) is not dict or len(counts) > 1: fail('producer_counts')
    normalized = {uid(key): number(value, 0, 1000000000) for key, value in counts.items()}
    if normalized and set(normalized) != {producer}: fail('producer_counts', 403)
    pin = record['pinVersion']; shape(pin, ('sequence', 'device'))
    number(pin['sequence'])
    if type(pin['device']) is not str or len(pin['device'].encode('utf-8')) > 128 or any(ord(c) < 32 for c in pin['device']): fail('pin_version')
    return dict(record, counts={producer: normalized.get(producer, 0)})


def merge(old, new, producer):
    if old is None: return new
    a, b = old['pinVersion'], new['pinVersion']
    av, bv = (a['sequence'], a['device']), (b['sequence'], b['device'])
    if av == bv and old['pinned'] != new['pinned']: fail('pin_version_conflict', 409)
    pin = new if bv > av else old
    if new['generation'] > old['generation']: result = dict(new)
    elif new['generation'] < old['generation']: result = dict(old)
    else:
        result = dict(old, deleted=old['deleted'] or new['deleted'], counts={producer: max(old['counts'][producer], new['counts'][producer])})
    result['pinned'], result['pinVersion'] = pin['pinned'], pin['pinVersion']
    return result


def ingest(store, who, body):
    shape(body, ('generation', 'consent_version', 'installation_id', 'producer_id', 'publication_id', 'history_mode', 'records'))
    group, consent = store.require_enabled(who)
    generation = number(body['generation']); cv = number(body['consent_version'])
    install, producer, publication = (uid(body[k]) for k in ('installation_id', 'producer_id', 'publication_id'))
    if generation != group['generation']: fail('generation_stale', 409)
    if cv != consent['version'] or install != consent['installation_id']: fail('consent_stale', 409)
    mode = body['history_mode']
    if mode not in ('historical_undated', 'incremental'): fail('history_mode')
    records = body['records']
    if type(records) is not list or len(records) > MAX_RECORDS: fail('batch_size', 413)
    key = (who.group, generation, producer)
    registry = store.db.execute('SELECT * FROM cl_producers WHERE group_id=? AND generation=? AND producer_id=?', key).fetchone()
    if registry and (registry['device_id'] != who.sender or registry['fingerprint'] != fingerprint(who)): fail('producer_owned_by_other_device', 403)
    previous = store.db.execute('SELECT body_hash,receipt FROM cl_publications WHERE group_id=? AND generation=? AND producer_id=? AND publication_id=?', key + (publication,)).fetchone()
    digest = hashlib.sha256(encode(body)).hexdigest()
    if previous:
        if previous['body_hash'] != digest: fail('publication_conflict', 409)
        return decode(previous['receipt'])
    if registry is None:
        if mode != 'historical_undated': fail('producer_bootstrap_required', 409)
        if store.db.execute('SELECT COUNT(*) FROM cl_producers WHERE group_id=? AND generation=? AND device_id=?', (who.group, generation, who.sender)).fetchone()[0] >= 8: fail('producer_capacity', 413)
        if store.db.execute('SELECT COUNT(*) FROM cl_producers WHERE group_id=? AND generation=?', (who.group, generation)).fetchone()[0] >= 64: fail('producer_capacity', 503)
    if store.db.execute('SELECT COUNT(*) FROM cl_publications WHERE group_id=?', (who.group,)).fetchone()[0] >= 100000: fail('learning_capacity', 503)
    seen, changed, now = set(), 0, int(store.clock())
    for candidate in records:
        record = validate(store, candidate, producer); term = (record['reading'], record['text'])
        if term in seen: fail('duplicate_component')
        seen.add(term)
        row = store.db.execute('SELECT * FROM cl_components WHERE group_id=? AND generation=? AND producer_id=? AND reading=? AND text=?', key + term).fetchone()
        old = decode(row['record_json']) if row else None
        result = merge(old, record, producer)
        if result == old: continue
        if row is None:
            if store.db.execute('SELECT COUNT(*) FROM cl_components WHERE group_id=? AND generation=?', (who.group, generation)).fetchone()[0] >= MAX_COMPONENT_ROWS: fail('component_capacity', 503)
            exists = store.db.execute('SELECT 1 FROM cl_components WHERE group_id=? AND generation=? AND reading=? AND text=? LIMIT 1', (who.group, generation) + term).fetchone()
            total = store.db.execute('SELECT COUNT(*) FROM (SELECT reading,text FROM cl_components WHERE group_id=? AND generation=? GROUP BY reading,text)', (who.group, generation)).fetchone()[0]
            if not exists and total >= MAX_TERMS: fail('term_capacity', 503)
        count = result['counts'][producer]
        same = old is not None and old['generation'] == result['generation']
        previous_count = old['counts'][producer] if same else 0
        increase = max(0, count - previous_count)
        score = row['score'] * math.pow(2.0, -max(0, now - row['decayed_at']) / HALF_LIFE) if row and same else 0
        undated = row['undated_count'] if row and same else 0
        if mode == 'historical_undated': undated += increase
        score = min(MAX_SCORE, score + increase * (100 if mode == 'historical_undated' else 1000))
        if result['deleted']: score = 0
        store.db.execute('INSERT OR REPLACE INTO cl_components VALUES(?,?,?,?,?,?,?,?,?)', key + term + (encode(result), score, now, undated))
        changed += 1
    merged = [decode(row[0]) for row in store.db.execute('SELECT record_json FROM cl_components WHERE group_id=? AND generation=? AND producer_id=?', key)]
    full_digest = component_digest(producer, merged)
    revision = (registry['revision'] if registry else 0) + int(changed > 0 or registry is None)
    store.db.execute('INSERT OR REPLACE INTO cl_producers VALUES(?,?,?,?,?,?,?,?,?)', key + (who.sender, install, cv, fingerprint(who), revision, full_digest))
    receipt = {'accepted_publication_id': publication, 'producer_id': producer, 'producer_revision': revision, 'changed_records': changed, 'generation': generation, 'consent_version': cv, 'component_digest': full_digest}
    store.db.execute('INSERT INTO cl_publications VALUES(?,?,?,?,?,?)', key + (publication, digest, encode(receipt)))
    return receipt


def projection(store, gid, generation, valid, now, *, decay_due=False):
    """Return immutable snapshot candidates/tombstones and exact consumed producers."""
    lexemes, watermarks = {}, []
    for producer in store.db.execute('SELECT * FROM cl_producers WHERE group_id=? AND generation=? ORDER BY producer_id', (gid, generation)).fetchall():
        dkey = (producer['device_id'], producer['installation_id'], producer['consent_version'])
        if dkey not in valid or producer['fingerprint'] != fingerprint(valid[dkey]): continue
        watermarks.append({'producer_id': producer['producer_id'], 'producer_revision': producer['revision'], 'component_digest': producer['digest']})
        for row in store.db.execute('SELECT rowid,* FROM cl_components WHERE group_id=? AND generation=? AND producer_id=?', (gid, generation, producer['producer_id'])).fetchall():
            score = row['score']
            if decay_due:
                score *= math.pow(2.0, -max(0, now - row['decayed_at']) / HALF_LIFE)
                store.db.execute('UPDATE cl_components SET score=?,decayed_at=? WHERE rowid=?', (score, now, row['rowid']))
            record = decode(row['record_json'])
            lexemes.setdefault((record['reading'], record['text']), []).append((record, score))
    active, deleted = {}, {}
    for (reading, text), values in lexemes.items():
        tg = max(record['generation'] for record, _ in values)
        removed = any(record['deleted'] for record, _ in values if record['generation'] == tg)
        pin = max((record for record, _ in values), key=lambda x: (x['pinVersion']['sequence'], x['pinVersion']['device']))
        item = {'reading': reading, 'text': text, 'layout': 'shared', 'term_generation': tg}
        key = ('shared', reading, text)
        if removed: deleted[key] = item
        else:
            item.update(weight=min(MAX_SCORE, max(0, int(sum(score for record, score in values if record['generation'] == tg)))), pinned=pin['pinned'])
            active[key] = item
    return active, deleted, watermarks


def bootstrap(store, who, body):
    """Own-producer recovery only; does not claim/activate a registry binding."""
    shape(body, ('generation', 'consent_version', 'installation_id', 'producer_id'))
    group, consent = store.require_enabled(who)
    generation, cv = number(body['generation']), number(body['consent_version'])
    install, producer = uid(body['installation_id']), uid(body['producer_id'])
    if generation != group['generation']: fail('generation_stale', 409)
    if cv != consent['version'] or install != consent['installation_id']: fail('consent_stale', 409)
    key = (who.group, generation, producer)
    registry = store.db.execute('SELECT * FROM cl_producers WHERE group_id=? AND generation=? AND producer_id=?', key).fetchone()
    if registry and (registry['device_id'] != who.sender or registry['fingerprint'] != fingerprint(who)):
        fail('producer_owned_by_other_device', 403)
    records = [decode(row[0]) for row in store.db.execute('SELECT record_json FROM cl_components WHERE group_id=? AND generation=? AND producer_id=? ORDER BY reading,text', key)] if registry else []
    if len(records) > MAX_TERMS: fail('component_capacity', 503)
    digest = component_digest(producer, records)
    if registry and registry['digest'] != digest: fail('component_state_mismatch', 503)
    result = {'exists': registry is not None, 'producer_id': producer,
              'producer_revision': registry['revision'] if registry else 0,
              'component_digest': digest, 'records': records}
    if len(encode(result)) > 4 * 1024 * 1024: fail('response_size', 413)
    return result
