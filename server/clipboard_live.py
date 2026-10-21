"""Bounded ciphertext-only clipboard delivery, independent of legacy FIFO/ledger.

Certificates are issued by existing members, not new virtual group members.
No group key, clipboard plaintext, primary key or decryption service exists here.
"""
import base64
import hashlib

VERSION = 1
LEASE = 30 * 86400
TTL = 600
MAX_BODY = 131072
MAX_RESPONSE = 1048576
MAX_CURSOR = (1 << 63) - 1
TABLES = {'clipboard_live_heads', 'clipboard_live_events', 'clipboard_live_receipts',
          'clipboard_live_nonces', 'clipboard_live_grants', 'clipboard_live_revoked'}


def initialize(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS clipboard_live_heads(group_id TEXT PRIMARY KEY,head INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS clipboard_live_events(group_id TEXT NOT NULL,cursor INTEGER NOT NULL,sender TEXT NOT NULL,event TEXT NOT NULL,epoch TEXT NOT NULL,kind TEXT NOT NULL,expires INTEGER NOT NULL,wire BLOB NOT NULL,PRIMARY KEY(group_id,cursor));
    CREATE TABLE IF NOT EXISTS clipboard_live_receipts(group_id TEXT NOT NULL,sender TEXT NOT NULL,event TEXT NOT NULL,epoch TEXT NOT NULL,kind TEXT NOT NULL,digest BLOB NOT NULL,expires INTEGER NOT NULL,crypto_nonce BLOB,PRIMARY KEY(group_id,epoch,sender,event,kind),UNIQUE(group_id,epoch,sender,crypto_nonce));
    CREATE TABLE IF NOT EXISTS clipboard_live_nonces(group_id TEXT NOT NULL,parent TEXT NOT NULL,nonce TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(group_id,parent,nonce));
    CREATE TABLE IF NOT EXISTS clipboard_live_grants(group_id TEXT NOT NULL,parent TEXT NOT NULL,epoch TEXT NOT NULL,generation TEXT NOT NULL,issued INTEGER NOT NULL,expires INTEGER NOT NULL,digest BLOB NOT NULL,PRIMARY KEY(group_id,parent,epoch));
    CREATE TABLE IF NOT EXISTS clipboard_live_revoked(group_id TEXT NOT NULL,parent TEXT NOT NULL,epoch TEXT NOT NULL,generation TEXT NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(group_id,parent,epoch,generation));
    ''')


def capabilities():
    return {'version': 1, 'supported': True, 'pollSeconds': 3, 'maxItems': 32,
            'maxTextBytes': 65536, 'maxBodyBytes': MAX_BODY,
            'maxResponseBytes': MAX_RESPONSE, 'ttlSeconds': TTL, 'maxLeaseSeconds': LEASE}


def certificate_bytes(cert):
    from private_input_relay import shape, number, identifier, b64, integer_bytes, reject
    shape(cert, 'version group parent epoch generation signingPublic delegatePublic issuedAt expiresAt signature')
    if number(cert['version'], 1, 1) != VERSION:
        reject('live_version')
    issued = number(cert['issuedAt'], 0, MAX_CURSOR)
    expires = number(cert['expiresAt'], issued + 1, MAX_CURSOR)
    if expires - issued > LEASE:
        reject('live_lease')
    return (b'PrivateInput/clipboard-live-certificate/v1\0\x01' + identifier(cert['group'])[1]
            + identifier(cert['parent'])[1] + integer_bytes(number(cert['epoch'], 1))
            + identifier(cert['generation'])[1] + b64(cert['signingPublic'], 32, 32)
            + b64(cert['delegatePublic'], 32, 32) + integer_bytes(issued) + integer_bytes(expires))


def certificate_digest(cert):
    from private_input_relay import b64
    return hashlib.sha256(certificate_bytes(cert) + b64(cert['signature'], 64, 64)).digest()


def event_header(event):
    from private_input_relay import shape, number, identifier, b64, integer_bytes, reject
    shape(event, 'version group sender event epoch issuedAt expiresAt nonce ciphertext certificate signature')
    number(event['version'], 1, 1)
    issued = number(event['issuedAt'], 0, MAX_CURSOR)
    expires = number(event['expiresAt'], issued + 1, MAX_CURSOR)
    if expires - issued > TTL:
        reject('live_ttl')
    b64(event['ciphertext'], 16, 65552)
    return (b'PrivateInput/clipboard-live-event/v1\0\x01' + identifier(event['group'])[1]
            + identifier(event['sender'])[1] + identifier(event['event'])[1]
            + integer_bytes(number(event['epoch'], 1)) + integer_bytes(issued)
            + integer_bytes(expires) + b64(event['nonce'], 12, 12)
            + certificate_digest(event['certificate']))


def request_header(request):
    from private_input_relay import shape, number, identifier, b64, integer_bytes
    shape(request, 'version group sender epoch nonce issuedAt certificate body signature')
    number(request['version'], 1, 1)
    return (b'PrivateInput/clipboard-live-request/v1\0\x01' + identifier(request['group'])[1]
            + identifier(request['sender'])[1] + integer_bytes(number(request['epoch'], 1))
            + identifier(request['nonce'])[1] + integer_bytes(number(request['issuedAt'], 0, MAX_CURSOR))
            + certificate_digest(request['certificate']) + hashlib.sha256(b64(request['body'], 1, MAX_BODY)).digest())


def revoke_header(request):
    from private_input_relay import shape, number, identifier, integer_bytes
    shape(request, 'version group parent epoch generation issuedAt nonce signature')
    number(request['version'], 1, 1)
    return (b'PrivateInput/clipboard-live-revoke/v1\0\x01' + identifier(request['group'])[1]
            + identifier(request['parent'])[1] + integer_bytes(number(request['epoch'], 1))
            + identifier(request['generation'])[1] + integer_bytes(number(request['issuedAt'], 0, MAX_CURSOR))
            + identifier(request['nonce'])[1])


def _member(relay, group, parent, epoch, now):
    from private_input_relay import b64, reject
    import device_administration
    state = relay.state(group)
    member = relay.member(state, parent)
    if state['epoch'] != epoch or not member['permissions'] & 2:
        reject('live_epoch_or_permission', 403)
    device_administration.authorized_activity(relay, group, parent, now)
    return b64(member['signingPublic'], 32, 32)


def _validate_cert(relay, cert, group, parent, epoch, now, activate=True):
    from private_input_relay import identifier, b64, verify_signature, reject
    canonical = certificate_bytes(cert)
    if identifier(cert['group'])[0] != group or identifier(cert['parent'])[0] != parent or cert['epoch'] != epoch:
        reject('live_certificate_binding', 403)
    if cert['issuedAt'] > now + 300 or cert['expiresAt'] <= now:
        reject('live_certificate_expired', 410)
    public = _member(relay, group, parent, epoch, now)
    if public != b64(cert['signingPublic'], 32, 32):
        reject('live_member_key', 403)
    verify_signature(public, b64(cert['signature'], 64, 64), canonical)
    generation = identifier(cert['generation'])[0]
    if relay.db.execute('SELECT 1 FROM clipboard_live_revoked WHERE group_id=? AND parent=? AND epoch=? AND generation=?',
                        (group, parent, str(epoch), generation)).fetchone():
        reject('live_grant_revoked', 403)
    digest = certificate_digest(cert)
    prior = relay.db.execute('SELECT issued,digest FROM clipboard_live_grants WHERE group_id=? AND parent=? AND epoch=?',
                             (group, parent, str(epoch))).fetchone()
    if prior and prior[1] != digest:
        if cert['issuedAt'] < prior[0]:
            reject('live_grant_stale', 403)
        if cert['issuedAt'] == prior[0]:
            reject('live_grant_conflict', 409)
    if activate and (not prior or prior[1] != digest):
        relay.db.execute('INSERT INTO clipboard_live_grants VALUES(?,?,?,?,?,?,?) ON CONFLICT(group_id,parent,epoch) DO UPDATE SET generation=excluded.generation,issued=excluded.issued,expires=excluded.expires,digest=excluded.digest',
                         (group, parent, str(epoch), generation, cert['issuedAt'], cert['issuedAt'] + LEASE + 300, digest))
    return digest, b64(cert['delegatePublic'], 32, 32)


def _nonce(relay, group, parent, value, now):
    from private_input_relay import identifier, reject
    nonce = identifier(value)[0]
    if relay.db.execute('SELECT 1 FROM clipboard_live_nonces WHERE group_id=? AND parent=? AND nonce=?', (group, parent, nonce)).fetchone():
        reject('live_request_replay', 409)
    count = relay.db.execute('SELECT count(*) FROM clipboard_live_nonces WHERE group_id=?', (group,)).fetchone()[0]
    if count >= 8192:
        reject('live_nonce_quota', 429)
    relay.db.execute('INSERT INTO clipboard_live_nonces VALUES(?,?,?,?)', (group, parent, nonce, now + TTL))


def _append(relay, group, sender, event, epoch, kind, expires, wire, digest, crypto_nonce=None):
    from private_input_relay import reject
    row = relay.db.execute('SELECT digest FROM clipboard_live_receipts WHERE group_id=? AND epoch=? AND sender=? AND event=? AND kind=?',
                           (group, str(epoch), sender, event, kind)).fetchone()
    if row:
        if row[0] != digest:
            reject('live_event_conflict', 409)
        return
    if crypto_nonce is not None and relay.db.execute('SELECT 1 FROM clipboard_live_receipts WHERE group_id=? AND epoch=? AND sender=? AND crypto_nonce=?',
                                                    (group, str(epoch), sender, crypto_nonce)).fetchone():
        reject('live_crypto_nonce_reuse', 409)
    counterpart = relay.db.execute('SELECT 1 FROM clipboard_live_receipts WHERE group_id=? AND epoch=? AND sender=? AND event=?',
                                    (group, str(epoch), sender, event)).fetchone()
    if counterpart:
        relay.db.execute('INSERT INTO clipboard_live_receipts VALUES(?,?,?,?,?,?,?,?)', (group, sender, event, str(epoch), kind, digest, expires, crypto_nonce))
        return
    count, size = relay.db.execute('SELECT count(*),coalesce(sum(length(wire)),0) FROM clipboard_live_events WHERE group_id=?', (group,)).fetchone()
    if count >= 256 or size + len(wire) > 32 * 1024 * 1024:
        reject('live_feed_quota', 429)
    head_row = relay.db.execute('SELECT head FROM clipboard_live_heads WHERE group_id=?', (group,)).fetchone()
    head = (head_row[0] if head_row else 0) + 1
    if head > MAX_CURSOR:
        reject('live_cursor_exhausted', 429)
    relay.db.execute('INSERT INTO clipboard_live_heads VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET head=excluded.head', (group, head))
    relay.db.execute('INSERT INTO clipboard_live_events VALUES(?,?,?,?,?,?,?,?)', (group, head, sender, event, str(epoch), kind, expires, wire))
    relay.db.execute('INSERT INTO clipboard_live_receipts VALUES(?,?,?,?,?,?,?,?)', (group, sender, event, str(epoch), kind, digest, expires, crypto_nonce))


def mirror_legacy(relay, group, message):
    """Best-effort SAVEPOINT: optional failure must never roll back legacy push."""
    if message.get('domain') != 2:
        return
    from private_input_relay import identifier, encoded, envelope_bytes
    relay.db.execute('SAVEPOINT clipboard_live_mirror')
    try:
        _, sender, event, header, cipher = envelope_bytes(message)
        _append(relay, group, sender, event, message['epoch'], 'legacy', message['expiresAt'],
                encoded(message), hashlib.sha256(header + cipher).digest())
        relay.db.execute('RELEASE clipboard_live_mirror')
    except Exception:
        relay.db.execute('ROLLBACK TO clipboard_live_mirror')
        relay.db.execute('RELEASE clipboard_live_mirror')


def batch(relay, request):
    from private_input_relay import identifier, number, b64, strict_json, shape, verify_signature, encoded, reject
    header = request_header(request)
    group = identifier(request['group'])[0]
    parent = identifier(request['sender'])[0]
    epoch = number(request['epoch'], 1)
    now = int(relay.clock())
    if abs(now - request['issuedAt']) >= 300:
        reject('live_request_expired', 410)
    body = strict_json(b64(request['body'], 1, MAX_BODY))
    shape(body, 'after limit publish')
    after = number(body['after'], 0, MAX_CURSOR)
    limit = number(body['limit'], 1, 32)
    with relay.transaction():
        digest, delegate = _validate_cert(relay, request['certificate'], group, parent, epoch, now, activate=False)
        verify_signature(delegate, b64(request['signature'], 64, 64), header)
        _validate_cert(relay, request['certificate'], group, parent, epoch, now)
        _nonce(relay, group, parent, request['nonce'], now)
        accepted = None
        if body['publish'] is not None:
            event = body['publish']
            canonical = event_header(event)
            if identifier(event['group'])[0] != group or identifier(event['sender'])[0] != parent or event['epoch'] != epoch or certificate_digest(event['certificate']) != digest:
                reject('live_event_binding', 403)
            if event['issuedAt'] > now + 300 or event['expiresAt'] <= now or event['expiresAt'] > request['certificate']['expiresAt']:
                reject('live_event_expired', 410)
            cipher = b64(event['ciphertext'], 16, 65552)
            verify_signature(delegate, b64(event['signature'], 64, 64), canonical + cipher)
            accepted = identifier(event['event'])[0]
            _append(relay, group, parent, accepted, epoch, 'live', event['expiresAt'], encoded(event), hashlib.sha256(canonical + cipher).digest(), b64(event['nonce'], 12, 12))
        head_row = relay.db.execute('SELECT head FROM clipboard_live_heads WHERE group_id=?', (group,)).fetchone()
        head = head_row[0] if head_row else 0
        if after > head:
            reject('live_cursor_ahead', 409)
        response = {'version': 1, 'accepted': accepted, 'head': head, 'next': after, 'items': []}
        rows = relay.db.execute('SELECT cursor,sender,epoch,kind,wire,expires FROM clipboard_live_events WHERE group_id=? AND cursor>? ORDER BY cursor', (group, after)).fetchall()
        state = relay.state(group)
        members = {identifier(m['device'])[0]: m for m in state['members']}
        import device_administration
        for cursor, sender, row_epoch, kind, wire, expires in rows:
            if expires <= now:
                response['next'] = cursor
                continue
            # Never deliver an old-epoch/left/inactive member's retained body.
            member = members.get(sender)
            departed = relay.db.execute('SELECT 1 FROM departed_devices WHERE group_id=? AND device=?', (group, sender)).fetchone()
            inactive = device_administration.expired(device_administration.profile(relay, group, sender), now)
            if int(row_epoch) != epoch or not member or not member['permissions'] & 2 or departed or inactive:
                response['next'] = cursor
                continue
            item = {'cursor': cursor, 'kind': kind, 'wire': base64.b64encode(wire).decode('ascii')}
            candidate = dict(response, next=cursor, items=response['items'] + [item])
            if len(encoded(candidate)) > MAX_RESPONSE:
                break
            response = candidate
            if len(response['items']) >= limit:
                break
        else:
            response['next'] = head
        return response


def revoke(relay, request):
    from private_input_relay import identifier, number, b64, verify_signature, reject
    header = revoke_header(request)
    group = identifier(request['group'])[0]
    parent = identifier(request['parent'])[0]
    generation = identifier(request['generation'])[0]
    epoch = number(request['epoch'], 1)
    now = int(relay.clock())
    if abs(now - request['issuedAt']) >= 300:
        reject('live_request_expired', 410)
    with relay.transaction():
        public = _member(relay, group, parent, epoch, now)
        verify_signature(public, b64(request['signature'], 64, 64), header)
        _nonce(relay, group, parent, request['nonce'], now)
        relay.db.execute('INSERT INTO clipboard_live_revoked VALUES(?,?,?,?,?) ON CONFLICT(group_id,parent,epoch,generation) DO UPDATE SET expires=max(expires,excluded.expires)',
                         (group, parent, str(epoch), generation, now + LEASE + 300))
        # Keep the greatest issuedAt watermark: deleting a revoked newer grant
        # would otherwise let an older, still-valid certificate register again.
        return {'version': 1, 'revoked': True, 'generation': generation}
