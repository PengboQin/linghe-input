"""Short lived, single recipient rendezvous. No content or group keys live here.

The operator is trusted for admission while a ticket is open. Signatures and
client side ECDH continue to protect membership and content after admission.
"""
import hashlib
import secrets
from urllib.parse import urlsplit


def initialize(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS pairing_tickets(id TEXT PRIMARY KEY,group_id TEXT NOT NULL,sponsor TEXT NOT NULL,expires INTEGER NOT NULL,code TEXT UNIQUE NOT NULL,secret_hash BLOB NOT NULL,invitation BLOB NOT NULL,claim BLOB);
    CREATE TABLE IF NOT EXISTS pairing_attempts(peer TEXT NOT NULL,issued INTEGER NOT NULL);
    ''')


def owner_rpc(relay, group, sender, operation, body, now):
    from private_input_relay import strict_json, shape, identifier, number, b64, encoded, reject
    state = relay.state(group)
    if operation == 8:
        member = relay.member(state, sender)
        if member['permissions'] != 3:
            reject('invite_permission', 403)
        value = strict_json(body); shape(value, 'ticket secretHash invitation expiresAt')
        ticket = identifier(value['ticket'])[0]
        expires = number(value['expiresAt'], now + 1, now + 300)
        secret_hash = b64(value['secretHash'], 32, 32)
        invitation = value['invitation']; shape(invitation, 'version endpoint anchor')
        anchor = invitation['anchor']; shape(anchor, 'group ownerID ownerPublic')
        if invitation['version'] != 1 or anchor['group'].upper() != group or anchor['ownerID'] != state['ownerID'] or anchor['ownerPublic'] != state['ownerPublic']:
            reject('invitation', 400)
        endpoint = urlsplit(invitation['endpoint'])
        if endpoint.scheme != 'https' or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
            reject('endpoint', 400)
        if relay.db.execute('SELECT count(*) FROM pairing_tickets').fetchone()[0] >= 256:
            reject('quota', 429)
        old = relay.db.execute('SELECT code,expires,secret_hash,invitation FROM pairing_tickets WHERE id=? AND group_id=? AND sponsor=?', (ticket, group, sender)).fetchone()
        if old:
            if old[2] != secret_hash or old[3] != encoded(invitation): reject('ticket_conflict', 409)
            return {'ticket':ticket, 'code':old[0], 'expiresAt':old[1]}
        relay.db.execute('DELETE FROM pairing_tickets WHERE group_id=? AND sponsor=?', (group,sender))
        for _ in range(32):
            code = str(secrets.randbelow(1000000)).zfill(6)
            if not relay.db.execute('SELECT 1 FROM pairing_tickets WHERE code=?',(code,)).fetchone(): break
        else: reject('quota',429)
        relay.db.execute('INSERT INTO pairing_tickets VALUES(?,?,?,?,?,?,?,NULL)', (ticket,group,sender,expires,code,secret_hash,encoded(invitation)))
        return {'ticket':ticket,'code':code,'expiresAt':expires}
    if operation == 9:
        if body: reject()
        members = {identifier(m['device'])[0] for m in state['members']}
        if sender!=identifier(state['ownerID'])[0] and relay.member(state,sender)['permissions']!=3:reject('invite_permission',403)
        rows = relay.db.execute('SELECT id,sponsor,expires,claim FROM pairing_tickets WHERE group_id=? AND claim IS NOT NULL',(group,)).fetchall()
        return {'claims':[{'ticket':r[0],'sponsor':r[1],'expiresAt':r[2],'request':strict_json(r[3])} for r in rows if (sender==identifier(state['ownerID'])[0] or identifier(r[1])[0]==sender) and r[2]>now and strict_json(r[3])['expiresAt']>now and identifier(strict_json(r[3])['member']['device'])[0] not in members and not relay.db.execute('SELECT 1 FROM admissions WHERE group_id=? AND session=?',(group,identifier(strict_json(r[3])['session'])[0])).fetchone()]}
    value = strict_json(body); shape(value,'ticket'); ticket = identifier(value['ticket'])[0]
    relay.db.execute('DELETE FROM pairing_tickets WHERE id=? AND group_id=? AND (sponsor=? OR ?=?)',(ticket,group,sender,sender,identifier(state['ownerID'])[0]))
    return {'accepted':True}


def claim(relay, value, peer):
    from private_input_relay import shape, identifier, b64, encoded, reject, strict_json, pair_request_bytes
    now = int(relay.clock())
    # Commit the budget before validating credentials; failures must consume it.
    with relay.transaction():
        relay.db.execute('DELETE FROM pairing_attempts WHERE issued<=?',(now-60,))
        peer_hash=hashlib.sha256(peer.encode()).hexdigest()
        if relay.db.execute('SELECT count(*) FROM pairing_attempts').fetchone()[0]>=10 or relay.db.execute('SELECT count(*) FROM pairing_attempts WHERE peer=?',(peer_hash,)).fetchone()[0]>=5: reject('pair_rate',429)
        relay.db.execute('INSERT INTO pairing_attempts VALUES(?,?)',(peer_hash,now))
    with relay.transaction():
        shape(value,'code request' if 'code' in value else 'ticket secret request')
        request=value['request']; session,sender,_,digest=pair_request_bytes(request,now)
        if 'code' in value:
            code=value['code']
            if type(code) is not str or len(code)!=6 or not code.isascii() or not code.isdecimal(): reject('pair_unavailable',404)
            row=relay.db.execute('SELECT id,group_id,secret_hash,invitation,claim FROM pairing_tickets WHERE code=?',(code,)).fetchone()
        else:
            ticket=identifier(value['ticket'])[0]
            row=relay.db.execute('SELECT id,group_id,secret_hash,invitation,claim FROM pairing_tickets WHERE id=?',(ticket,)).fetchone()
            secret=b64(value['secret'],32,32)
            if row and not secrets.compare_digest(hashlib.sha256(secret).digest(),row[2]): row=None
        if not row: reject('pair_unavailable',404)
        ticket,group,_,invitation,old=row
        if old and pair_request_bytes(strict_json(old),now)[3]!=digest: reject('pair_unavailable',404)
        state=relay.state(group)
        if not old and any(identifier(m['device'])[0]==sender for m in state['members']): reject('already_member',409)
        if relay.db.execute('SELECT count(*) FROM pair_sessions WHERE group_id=?',(group,)).fetchone()[0]>=8 and not relay.db.execute('SELECT 1 FROM pair_sessions WHERE group_id=? AND session=?',(group,session)).fetchone(): reject('quota',429)
        existing=relay.db.execute('SELECT request FROM pair_sessions WHERE group_id=? AND session=?',(group,session)).fetchone()
        if existing and pair_request_bytes(strict_json(existing[0]),now)[3]!=digest: reject('pair_conflict',409)
        relay.db.execute('INSERT OR IGNORE INTO pair_sessions VALUES(?,?,?,?,?,NULL)',(group,session,sender,request['expiresAt'],encoded(request)))
        relay.db.execute('UPDATE pairing_tickets SET claim=? WHERE id=?',(encoded(request),ticket))
        return {'invitation':strict_json(invitation)}
