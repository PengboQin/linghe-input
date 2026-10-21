"""Ciphertext-only WSGI relay. Production requires HTTPS and a WSGI server.

The optional stdlib runner binds loopback only. No keys capable of decryption,
text indexes, request-body logging, product registration or accounts exist here.
"""
import argparse
import base64
from collections import OrderedDict, deque
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import threading
import time
import uuid
import quick_pairing
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature


class RelayError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def reject(code="invalid", status=400):
    raise RelayError(status, code)


def strict_json(data):
    def bounded_integer(value):
        if len(value) > 20:
            reject("integer_size")
        return int(value)
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                reject("duplicate_field")
            result[key] = value
        return result
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_int=bounded_integer,
                          parse_float=lambda _: reject("integer_required"),
                          parse_constant=lambda _: reject())
    except (ValueError, UnicodeError, RecursionError):
        reject()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def shape(value, fields):
    if type(value) is not dict or set(value) != set(fields.split()):
        reject()


def identifier(value):
    try:
        if type(value) is not str or len(value) != 36:
            reject()
        parsed = uuid.UUID(value)
        if value.lower() != str(parsed):
            reject()
        return str(parsed).upper(), parsed.bytes
    except ValueError:
        reject()


def number(value, minimum=0, maximum=(1 << 64) - 1):
    if type(value) is not int or not minimum <= value <= maximum:
        reject()
    return value


def b64(value, minimum=0, maximum=2097168):
    if type(value) is not str or len(value) > ((maximum + 2) // 3) * 4:
        reject()
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, UnicodeError):
        reject()
    if not minimum <= len(decoded) <= maximum:
        reject()
    return decoded


def integer_bytes(value):
    return struct.pack(">Q", number(value))


def verify_signature(public, signature, message):
    try:
        Ed25519PublicKey.from_public_bytes(public).verify(signature, message)
    except (ValueError, InvalidSignature):
        reject("signature", 401)


def membership_canonical(state):
    version=state.get('version')
    fields='version group ownerID ownerPublic revision epoch members signature'
    if version==2:
        fields+=' issuer parent'
        if 'history' in state: fields+=' history'
    shape(state,fields)
    if type(version) is not int or version not in (1,2): reject('version')
    group,gb=identifier(state['group']); _,ob=identifier(state['ownerID']);root=b64(state['ownerPublic'],32,32)
    revision=number(state['revision'],1)
    if number(state['epoch'],1)!=revision: reject()
    members=state['members']
    if type(members) is not list or not 1<=len(members)<=64: reject()
    parts=[];devices=set();signs=set();exchanges=set()
    for member in members:
        shape(member,'device signingPublic exchangePublic permissions')
        device,db=identifier(member['device']);sign=b64(member['signingPublic'],32,32);exchange=b64(member['exchangePublic'],32,32)
        if device in devices or sign in signs or exchange in exchanges: reject()
        devices.add(device);signs.add(sign);exchanges.add(exchange)
        parts.append((device,db+sign+exchange+bytes([number(member['permissions'],1,3)])))
    body=b'PrivateInput/membership/v1\0'+bytes([version])+gb+ob+root+integer_bytes(revision)+integer_bytes(revision)+bytes([len(members)])+b''.join(p for _,p in sorted(parts))
    if version==2:body+=identifier(state['issuer'])[1]+b64(state['parent'],32,32)
    return body


def authorization_public(state):
    if state['version']==1:return b64(state['ownerPublic'],32,32)
    previous=state.get('history',[])
    if not previous:reject('history')
    member=next((m for m in previous[-1]['members'] if identifier(m['device'])[0]==identifier(state['issuer'])[0]),None)
    if member is None or member['permissions']!=3:reject('admission_permission',403)
    return b64(member['signingPublic'],32,32)


def membership_bytes(state, require_signature=True):
    history=state.get('history',[])
    if type(history) is not list or len(history)>1024 or any('history' in x for x in history):reject('history')
    if (state['version']==2)!=bool(history):reject('history')
    previous=None;last=None
    for index,item in enumerate(history+[state]):
        body=membership_canonical(item)
        if any(item[k]!=state[k] for k in ('group','ownerID','ownerPublic')):reject('anchor',403)
        if previous is None:
            if item['version']!=1:reject('history')
            public=b64(item['ownerPublic'],32,32)
        else:
            if item['version']!=2 or item['revision']!=previous['revision']+1 or b64(item['parent'],32,32)!=hashlib.sha256(last).digest():reject('lineage',403)
            signer=next((m for m in previous['members'] if identifier(m['device'])[0]==identifier(item['issuer'])[0]),None)
            if signer is None or signer['permissions']!=3:reject('admission_permission',403)
            public=b64(signer['signingPublic'],32,32)
        if require_signature or index<len(history):verify_signature(public,b64(item['signature'],64,64),body)
        previous=item;last=body
    return identifier(state['group'])[0],b64(state['ownerPublic'],32,32),hashlib.sha256(last).digest()


def envelope_bytes(message):
    shape(message, "version group sender event epoch sequence domain issuedAt expiresAt ciphertext signature")
    if type(message["version"]) is not int or message["version"] != 1:
        reject("version")
    group, gb = identifier(message["group"])
    sender, sb = identifier(message["sender"])
    event, eb = identifier(message["event"])
    epoch, sequence = number(message["epoch"], 1), number(message["sequence"], 1)
    domain = number(message["domain"], 1, 2)
    issued = number(message["issuedAt"])
    expires = number(message["expiresAt"], issued + 1, (1 << 63) - 1)
    if expires - issued > (600 if domain == 2 else 604800):
        reject("expiry")
    cipher = b64(message["ciphertext"], 16, 65552 if domain == 2 else 2097168)
    header = (b"PrivateInput/event/v1\0" + b"\x01" + gb + sb + eb + integer_bytes(epoch)
              + integer_bytes(sequence) + bytes([domain]) + integer_bytes(issued) + integer_bytes(expires))
    return group, sender, event, header, cipher


def key_package_bytes(package, challenge=False):
    shape(package, "version purpose recipient ephemeralPublic context membership issuedAt expiresAt sealedKey signature")
    if type(package["version"]) is not int or package["version"] != 1:
        reject("version")
    purpose = number(package["purpose"], 1, 2)
    group, root, digest = membership_bytes(package["membership"], require_signature=not challenge)
    recipient, rb = identifier(package["recipient"])
    member = next((m for m in package["membership"]["members"] if identifier(m["device"])[0] == recipient), None)
    if member is None:
        reject("recipient", 403)
    context = b64(package["context"], 32, 32)
    if (purpose == 2) != (context == b"\0" * 32):
        reject()
    issued = number(package["issuedAt"]); expires = number(package["expiresAt"], issued + 1, (1 << 63) - 1)
    if expires - issued > (600 if purpose == 1 else 2592000):
        reject("expiry")
    header = (b"PrivateInput/wrapped-group-key/v1\0" + b"\x01" + bytes([purpose]) + rb
              + b64(member["exchangePublic"], 32, 32) + b64(package["ephemeralPublic"], 32, 32)
              + context + digest + integer_bytes(issued) + integer_bytes(expires))
    if challenge and (purpose != 1 or package["membership"]["signature"] != ""):
        reject("challenge_authorization")
    sealed = b64(package["sealedKey"], 0, 0) if challenge else b64(package["sealedKey"], 60, 60)
    verify_signature(authorization_public(package["membership"]), b64(package["signature"], 64, 64), header + sealed)
    return group, recipient, root, digest


def expire_rows(database, now):
    """Logical expiry only; callers hold an IMMEDIATE transaction."""
    database.execute("DELETE FROM recipients WHERE (group_id,sender,event) IN (SELECT group_id,sender,event FROM messages WHERE expires<=?)", (now,))
    database.execute("DELETE FROM pairing_tickets WHERE expires<=?", (now,))
    database.execute("DELETE FROM pairing_attempts WHERE issued<=?", (now-60,))
    for table in ("messages", "receipts", "nonces", "key_packages", "pair_sessions", "admissions"):
        database.execute("DELETE FROM " + table + " WHERE expires<=?", (now,))
    # Old databases remain valid; optional recency expiry never changes the
    # legacy queue or creates tables inside the maintenance operation.
    recent = {r[0] for r in database.execute("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('recent_snapshots','recent_receipts','recent_nonces')")}
    for table in recent:
        database.execute("DELETE FROM " + table + " WHERE expires<=?", (now,))
    if any(r[1] == 'expires' for r in database.execute('PRAGMA table_info(recent_capabilities)')):
        database.execute('DELETE FROM recent_capabilities WHERE expires<=?', (now,))
    # Optional live delivery has its own TTL and never consumes legacy rows.
    live = {r[0] for r in database.execute("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('clipboard_live_events','clipboard_live_receipts','clipboard_live_nonces','clipboard_live_grants','clipboard_live_revoked')")}
    for table in live:
        database.execute('DELETE FROM ' + table + ' WHERE expires<=?', (now,))


def pair_request_bytes(request, now):
    shape(request, "version session member challenge issuedAt expiresAt signature")
    if type(request["version"]) is not int or request["version"] != 1:
        reject("version")
    session, session_bytes = identifier(request["session"])
    member = request["member"]; shape(member, "device signingPublic exchangePublic permissions")
    sender, sender_bytes = identifier(member["device"])
    signing = b64(member["signingPublic"], 32, 32); exchange = b64(member["exchangePublic"], 32, 32)
    if number(member["permissions"], 1, 3) != 3:
        reject()
    issued = number(request["issuedAt"]); expires = number(request["expiresAt"], issued + 1, (1 << 63) - 1)
    if expires - issued > 600 or now >= expires or issued > now + 300:
        reject("expired", 410)
    body = b"PrivateInput/pair-request/v1\0" + b"\x01" + session_bytes + sender_bytes + signing + exchange + b64(request["challenge"], 32, 32) + integer_bytes(issued) + integer_bytes(expires)
    verify_signature(signing, b64(request["signature"], 64, 64), body)
    return session, sender, signing, hashlib.sha256(body).digest()


class Relay:
    def __init__(self, database, clock=time.time):
        path = Path(database)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.is_symlink():
            raise ValueError("Database path must be owned by this service")
        self.clock, self.lock = clock, threading.RLock()
        self.transaction_depth=0
        self.db = sqlite3.connect(str(path), isolation_level=None, timeout=2, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL"); self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA secure_delete=ON"); self.db.execute("PRAGMA trusted_schema=OFF")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY, root BLOB NOT NULL, revision TEXT NOT NULL, digest BLOB NOT NULL, state BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS messages(group_id TEXT NOT NULL, sender TEXT NOT NULL, event TEXT NOT NULL, expires INTEGER NOT NULL, wire BLOB NOT NULL, PRIMARY KEY(group_id,sender,event));
        CREATE TABLE IF NOT EXISTS recipients(group_id TEXT NOT NULL, sender TEXT NOT NULL, event TEXT NOT NULL, recipient TEXT NOT NULL, PRIMARY KEY(group_id,sender,event,recipient));
        CREATE TABLE IF NOT EXISTS receipts(group_id TEXT NOT NULL, sender TEXT NOT NULL, event TEXT NOT NULL, epoch TEXT NOT NULL, sequence TEXT NOT NULL, digest BLOB NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(group_id,sender,event), UNIQUE(group_id,sender,epoch,sequence));
        CREATE TABLE IF NOT EXISTS nonces(group_id TEXT NOT NULL, sender TEXT NOT NULL, nonce TEXT NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY(group_id,sender,nonce));
        CREATE TABLE IF NOT EXISTS windows(group_id TEXT NOT NULL, sender TEXT NOT NULL, epoch TEXT NOT NULL, highest TEXT NOT NULL, bitmap TEXT NOT NULL, PRIMARY KEY(group_id,sender,epoch));
        CREATE TABLE IF NOT EXISTS key_packages(group_id TEXT NOT NULL,recipient TEXT NOT NULL,expires INTEGER NOT NULL,wire BLOB NOT NULL,PRIMARY KEY(group_id,recipient));
        CREATE TABLE IF NOT EXISTS pair_sessions(group_id TEXT NOT NULL,session TEXT NOT NULL,sender TEXT NOT NULL,expires INTEGER NOT NULL,request BLOB NOT NULL,challenge BLOB,PRIMARY KEY(group_id,session));
        """)
        path.chmod(0o600)
        self.rates = OrderedDict()

        quick_pairing.initialize(self.db)
        self.db.execute('CREATE TABLE IF NOT EXISTS admissions(group_id TEXT NOT NULL,session TEXT NOT NULL,digest BLOB NOT NULL,expires INTEGER NOT NULL,PRIMARY KEY(group_id,session))')
        import device_administration
        device_administration.initialize(self.db)
        import recent_learning
        recent_learning.initialize(self.db)
        import clipboard_live
        clipboard_live.initialize(self.db)
        for row in self.db.execute('SELECT state FROM groups').fetchall():device_administration.remember_members(self,strict_json(row[0]))

    @contextmanager
    def transaction(self):
        with self.lock:
            if self.transaction_depth:
                self.transaction_depth+=1
                try:yield self.db
                finally:self.transaction_depth-=1
                return
            self.transaction_depth=1
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.clean(int(self.clock()))
                yield self.db
                self.db.execute("COMMIT")
            except Exception:
                self.db.execute("ROLLBACK")
                raise
            finally:
                self.transaction_depth=0

    def clean(self, now):
        expire_rows(self.db, now)

    def state(self, group):
        row = self.db.execute("SELECT state FROM groups WHERE id=?", (group,)).fetchone()
        if row is None:
            reject("group", 404)
        return strict_json(row[0])

    def member(self, state, sender):
        for member in state["members"]:
            if identifier(member["device"])[0] == sender:
                return member
        reject("member", 403)

    def register(self, state):
        group, root, digest = membership_bytes(state)
        if state["revision"] != 1 or len(state["members"]) != 1:
            reject("initial_state")
        with self.transaction():
            old = self.db.execute("SELECT digest FROM groups WHERE id=?", (group,)).fetchone()
            if old:
                if old[0] != digest:
                    reject("group_conflict", 409)
                return {"accepted": True}
            if self.db.execute("SELECT count(*) FROM groups").fetchone()[0] >= 1000:
                reject("quota", 429)
            self.db.execute("INSERT INTO groups VALUES(?,?,?,?,?)", (group, root, "1", digest, encoded(state)))
            import device_administration
            device_administration.remember_members(self,state)
        return {"accepted": True}

    def update(self, group, state):
        actual, root, digest = membership_bytes(state)
        if actual != group:
            reject("group")
        with self.transaction():
            old = self.state(group)
            if state['version']==1 and state['revision']!=old['revision'] and self.db.execute("SELECT 1 FROM device_profiles WHERE group_id=? AND kind!='unknown' LIMIT 1",(group,)).fetchone():reject('upgrade_required',403)
            if state['version']==2 and self.transaction_depth==1 and state['revision']!=old['revision']:reject('atomic_change_required',403)
            if b64(old["ownerPublic"], 32, 32) != root or identifier(old["ownerID"])[0] != identifier(state["ownerID"])[0]:
                reject("owner", 403)
            if state['version']==2 and state['revision']!=old['revision']:
                if state['revision']!=old['revision']+1 or b64(state['parent'],32,32)!=membership_bytes(old)[2]:reject('concurrent_change',409)
                import device_administration
                device_administration.authorize_change(self,group,old,state,int(self.clock()))
            if state["revision"] < old["revision"]:
                reject("rollback", 409)
            if state["revision"] == old["revision"]:
                if membership_bytes(old)[2] != digest:
                    reject("equivocation", 409)
                return {"accepted": True}
            import device_administration
            device_administration.remember_members(self,old);device_administration.remember_members(self,state)
            self.db.execute("UPDATE groups SET revision=?,digest=?,state=? WHERE id=?", (str(state["revision"]), digest, encoded(state), group))
            self.db.execute("DELETE FROM recipients WHERE group_id=?", (group,))
            self.db.execute("DELETE FROM messages WHERE group_id=?", (group,))
            self.db.execute("DELETE FROM windows WHERE group_id=?", (group,))
            self.db.execute("DELETE FROM key_packages WHERE group_id=?", (group,))
        return {"accepted": True}

    def change_members(self,group,value):
        shape(value,'membership packages')
        state=value['membership'];packages=value['packages']
        if type(packages) is list:packages=[dict(p,membership=state) if type(p) is dict and 'membership' not in p else p for p in packages]
        if state.get('version')!=2 or type(packages) is not list or len(packages)>64:reject('change')
        with self.transaction():
            old=self.state(group);old_ids={identifier(m['device'])[0] for m in old['members']};new_ids={identifier(m['device'])[0] for m in state['members']}
            if not new_ids<=old_ids:reject('use_admission',403)
            old_members={identifier(m['device'])[0]:m for m in old['members']}
            if any(m!=old_members[identifier(m['device'])[0]] for m in state['members']):reject('member_mutation',403)
            self.update(group,state)
            expected=new_ids;supplied=set()
            for package in packages:
                recipient=identifier(package['recipient'])[0]
                if recipient in supplied:reject('duplicate_package')
                supplied.add(recipient);self.store_key(group,package)
            if supplied!=expected:reject('missing_package')
        return {'accepted':True}

    def admit(self,group,value):
        shape(value,'session challenge membership packages')
        session=identifier(value['session'])[0];membership=value['membership'];packages=value['packages']
        if type(packages) is list:packages=[dict(p,membership=membership) if type(p) is dict and 'membership' not in p else p for p in packages]
        if type(value['challenge']) is dict and type(value['challenge'].get('template')) is dict and 'membership' not in value['challenge']['template']:
            unsigned=dict(membership,signature='');value=dict(value,challenge={'template':dict(value['challenge']['template'],membership=unsigned)})
        if type(packages) is not list or not 1<=len(packages)<=64:reject('packages')
        _,_,digest=membership_bytes(membership)
        if membership['version']!=2:reject('independent_admission_requires_v2')
        issuer=identifier(membership['issuer'])[0]
        with self.transaction():
            prior=self.db.execute('SELECT digest FROM admissions WHERE group_id=? AND session=?',(group,session)).fetchone()
            if prior:
                if prior[0]!=digest:reject('admission_conflict',409)
                return {'accepted':True}
            current=self.state(group)
            ticket=self.db.execute('SELECT sponsor,claim FROM pairing_tickets WHERE group_id=? AND claim IS NOT NULL',(group,)).fetchall()
            claim=next((strict_json(wire) for sponsor,wire in ticket if identifier(sponsor)[0]==issuer and identifier(strict_json(wire)['session'])[0]==session),None)
            if claim is None:reject('admission_ticket',403)
            recipient=identifier(claim['member']['device'])[0]
            expected={identifier(m['device'])[0] for m in current['members']}|{recipient}
            if {identifier(m['device'])[0] for m in membership['members']}!=expected or len(membership['members'])!=len(current['members'])+1:reject('admission_members',403)
            old={identifier(m['device'])[0]:m for m in current['members']}
            if any(old[identifier(m['device'])[0]]!=m for m in membership['members'] if identifier(m['device'])[0] in old):reject('admission_mutation',403)
            if next(m for m in membership['members'] if identifier(m['device'])[0]==recipient)!=claim['member']:reject('admission_recipient',403)
            if value['challenge'].get('template',{}).get('recipient','').upper()!=recipient:reject('challenge_recipient',403)
            self.store_challenge(group,{'session':session,'challenge':value['challenge']})
            self.update(group,membership)
            supplied=set()
            for package in packages:
                device=identifier(package['recipient'])[0]
                if device in supplied:reject('duplicate_package')
                supplied.add(device);self.store_key(group,package)
            if supplied!=expected:reject('missing_package')
            self.db.execute('INSERT INTO admissions VALUES(?,?,?,?)',(group,session,digest,claim['expiresAt']))
        return {'accepted':True}

    def push(self, group, message):
        actual, sender, event, header, cipher = envelope_bytes(message)
        if actual != group:
            reject("group")
        now = int(self.clock())
        if now >= message["expiresAt"] or message["issuedAt"] > now + 300:
            reject("expired", 410)
        with self.transaction():
            state = self.state(group); member = self.member(state, sender)
            if state["epoch"] != message["epoch"] or member["permissions"] & message["domain"] == 0:
                reject("epoch_or_permission", 403)
            verify_signature(b64(member["signingPublic"], 32, 32), b64(message["signature"], 64, 64), header + cipher)
            import device_administration
            device_administration.authorized_activity(self,group,sender,now)
            digest = hashlib.sha256(header + cipher).digest()
            old = self.db.execute("SELECT digest FROM receipts WHERE group_id=? AND sender=? AND event=?", (group, sender, event)).fetchone()
            if old:
                if old[0] != digest:
                    reject("event_conflict", 409)
                import clipboard_live
                clipboard_live.mirror_legacy(self, group, message)
                return {"accepted": True, "event": event}
            epoch, sequence = str(message["epoch"]), message["sequence"]
            row = self.db.execute("SELECT highest,bitmap FROM windows WHERE group_id=? AND sender=? AND epoch=?", (group, sender, epoch)).fetchone()
            highest, bitmap = sequence, 1
            if row:
                highest, bitmap = int(row[0]), int(row[1])
                if sequence > highest:
                    gap = sequence - highest
                    bitmap = 1 if gap >= 64 else ((bitmap << gap) | 1) & ((1 << 64) - 1)
                    highest = sequence
                else:
                    gap = highest - sequence
                    if gap >= 64 or bitmap & (1 << gap):
                        reject("replay", 409)
                    bitmap |= 1 << gap
            queued = self.db.execute("SELECT count(*),coalesce(sum(length(wire)),0) FROM messages WHERE group_id=?", (group,)).fetchone()
            wire = encoded(message)
            if queued[0] >= 256 or queued[1] + len(wire) > 32 * 1024 * 1024 or self.db.execute("SELECT count(*) FROM receipts WHERE group_id=?", (group,)).fetchone()[0] >= 32768:
                reject("quota", 429)
            self.db.execute("INSERT INTO receipts VALUES(?,?,?,?,?,?,?)", (group, sender, event, epoch, str(sequence), digest, message["expiresAt"]))
            self.db.execute("INSERT INTO windows VALUES(?,?,?,?,?) ON CONFLICT(group_id,sender,epoch) DO UPDATE SET highest=excluded.highest,bitmap=excluded.bitmap", (group, sender, epoch, str(highest), str(bitmap)))
            recipients = [identifier(m["device"])[0] for m in state["members"] if m["permissions"] & message["domain"] and identifier(m["device"])[0] != sender]
            if recipients:
                self.db.execute("INSERT INTO messages VALUES(?,?,?,?,?)", (group, sender, event, message["expiresAt"], wire))
                self.db.executemany("INSERT INTO recipients VALUES(?,?,?,?)", [(group, sender, event, recipient) for recipient in recipients])
            import clipboard_live
            clipboard_live.mirror_legacy(self, group, message)
        return {"accepted": True, "event": event}

    def store_key(self, group, package):
        actual, recipient, root, digest = key_package_bytes(package)
        now = int(self.clock())
        if actual != group or now >= package["expiresAt"] or package["issuedAt"] > now + 300:
            reject("group_or_expiry", 410)
        with self.transaction():
            current = self.state(group)
            if membership_bytes(current)[2] != digest:
                reject("membership", 403)
            self.member(current, recipient)
            self.db.execute("INSERT INTO key_packages VALUES(?,?,?,?) ON CONFLICT(group_id,recipient) DO UPDATE SET expires=excluded.expires,wire=excluded.wire", (group, recipient, package["expiresAt"], encoded(package)))
        return {"accepted": True}

    def store_challenge(self, group, value):
        shape(value, "session challenge"); shape(value["challenge"], "template")
        session = identifier(value["session"])[0]; template = value["challenge"]["template"]
        actual, recipient, root, _ = key_package_bytes(template, challenge=True)
        now = int(self.clock())
        if actual != group or now >= template["expiresAt"] or template["issuedAt"] > now + 300:
            reject("expired", 410)
        with self.transaction():
            current = self.state(group)
            if root != b64(current["ownerPublic"], 32, 32) or identifier(template["membership"]["ownerID"])[0] != identifier(current["ownerID"])[0]:
                reject("owner", 403)
            if template["membership"]["revision"] != current["revision"] + 1:
                reject("revision", 409)
            row = self.db.execute("SELECT request FROM pair_sessions WHERE group_id=? AND session=? AND sender=?", (group, session, recipient)).fetchone()
            if row is None:
                reject("pair", 404)
            request = strict_json(row[0]); _, _, _, digest = pair_request_bytes(request, now)
            proposed = next(m for m in template["membership"]["members"] if identifier(m["device"])[0] == recipient)
            if b64(template["context"], 32, 32) != digest or proposed["signingPublic"] != request["member"]["signingPublic"] or proposed["exchangePublic"] != request["member"]["exchangePublic"] or template["expiresAt"] > request["expiresAt"]:
                reject("binding", 403)
            self.db.execute("UPDATE pair_sessions SET challenge=? WHERE group_id=? AND session=?", (encoded(value["challenge"]), group, session))
        return {"accepted": True}

    def rpc(self, group, request):
        shape(request, "version group sender nonce issuedAt operation body signature")
        actual, gb = identifier(request["group"]); sender, sb = identifier(request["sender"]); nonce, nb = identifier(request["nonce"])
        issued, operation = number(request["issuedAt"]), number(request["operation"], 1, 14)
        if actual != group or type(request["version"]) is not int or request["version"] != 1:
            reject()
        body = b64(request["body"], maximum=65536)
        header = b"PrivateInput/relay-request/v1\0" + b"\x01" + gb + sb + nb + integer_bytes(issued) + bytes([operation]) + hashlib.sha256(body).digest()
        now = int(self.clock())
        if abs(now - issued) >= 300:
            reject("expired", 410)
        with self.transaction():
            state = self.state(group); member = None; temporary_pair = None
            if operation == 5 or (operation == 9 and sender == identifier(state["ownerID"])[0]):
                if sender != identifier(state["ownerID"])[0]:
                    reject("owner", 403)
                public = b64(state["ownerPublic"], 32, 32)
            elif operation == 7:
                temporary_pair = strict_json(body)
                _, pair_sender, public, _ = pair_request_bytes(temporary_pair, now)
                if pair_sender != sender:
                    reject("sender", 403)
            elif operation == 6:
                payload = strict_json(body); shape(payload, "session")
                session = identifier(payload["session"])[0]
                row = self.db.execute("SELECT request FROM pair_sessions WHERE group_id=? AND session=? AND sender=?", (group, session, sender)).fetchone()
                if row is None:
                    reject("pair", 404)
                _, _, public, _ = pair_request_bytes(strict_json(row[0]), now)
            elif operation==12:
                import device_administration
                row=device_administration.profile(self,group,sender)
                if row is None:
                    member=self.member(state,sender);public=b64(member['signingPublic'],32,32)
                else:public=row[3]
            else:
                member = self.member(state, sender); public = b64(member["signingPublic"], 32, 32)
            verify_signature(public, b64(request["signature"], 64, 64), header)
            import device_administration
            if member is not None and operation!=12:device_administration.authorized_activity(self,group,sender,now)
            if self.db.execute("SELECT 1 FROM nonces WHERE group_id=? AND sender=? AND nonce=?", (group, sender, nonce)).fetchone():
                reject("request_replay", 409)
            if self.db.execute("SELECT count(*) FROM nonces WHERE group_id=?", (group,)).fetchone()[0] >= 8192:
                reject("quota", 429)
            self.db.execute("INSERT INTO nonces VALUES(?,?,?,?)", (group, sender, nonce, now + 600))
            if operation in (11,12,13,14):
                return device_administration.rpc(self,group,sender,operation,body,now)
            if operation in (8, 9, 10):
                return quick_pairing.owner_rpc(self,group,sender,operation,body,now)
            if operation == 7:
                session = identifier(temporary_pair["session"])[0]
                old = self.db.execute("SELECT request FROM pair_sessions WHERE group_id=? AND session=?", (group, session)).fetchone()
                if old:
                    if pair_request_bytes(strict_json(old[0]), now)[3] != pair_request_bytes(temporary_pair, now)[3]:
                        reject("pair_conflict", 409)
                    return {"accepted": True}
                if self.db.execute("SELECT count(*) FROM pair_sessions WHERE group_id=?", (group,)).fetchone()[0] >= 8:
                    reject("quota", 429)
                self.db.execute("INSERT INTO pair_sessions VALUES(?,?,?,?,?,NULL)", (group, session, sender, temporary_pair["expiresAt"], encoded(temporary_pair)))
                return {"accepted": True}
            if operation == 5:
                if body:
                    reject()
                rows = self.db.execute("SELECT request FROM pair_sessions WHERE group_id=? ORDER BY rowid", (group,)).fetchall()
                members = {identifier(m["device"])[0] for m in state["members"]}
                return {"requests": [strict_json(row[0]) for row in rows if identifier(strict_json(row[0])["member"]["device"])[0] not in members]}
            if operation == 6:
                row = self.db.execute("SELECT challenge FROM pair_sessions WHERE group_id=? AND session=? AND sender=?", (group, session, sender)).fetchone()
                if row is None or row[0] is None:
                    reject("challenge_not_ready", 404)
                return {"challenge": strict_json(row[0])}
            if operation == 1:
                if body:
                    reject()
                return {"membership": state}
            if operation == 4:
                if body:
                    reject()
                row = self.db.execute("SELECT wire FROM key_packages WHERE group_id=? AND recipient=?", (group, sender)).fetchone()
                if row is None:
                    reject("key_not_ready", 404)
                return {"package": strict_json(row[0])}
            payload = strict_json(body)
            if operation == 2:
                shape(payload, "limit domains" if "domains" in payload else "limit")
                limit = number(payload["limit"], 1, 2)
                domains = number(payload.get("domains", 3), 1, 3) & member["permissions"]
                rows = self.db.execute("SELECT m.wire FROM messages m JOIN recipients r USING(group_id,sender,event) WHERE m.group_id=? AND r.recipient=? AND (json_extract(CAST(m.wire AS TEXT),'$.domain') & ?) != 0 ORDER BY m.rowid LIMIT ?", (group, sender, domains, limit)).fetchall()
                return {"events": [strict_json(row[0]) for row in rows]}
            shape(payload, "events")
            events = payload["events"]
            if type(events) is not list or len(events) > 100:
                reject()
            for item in events:
                event = identifier(item)[0]
                self.db.execute("DELETE FROM recipients WHERE group_id=? AND event=? AND recipient=?", (group, event, sender))
            self.db.execute("DELETE FROM messages WHERE group_id=? AND NOT EXISTS(SELECT 1 FROM recipients r WHERE r.group_id=messages.group_id AND r.sender=messages.sender AND r.event=messages.event)", (group,))
            return {"accepted": True}

    def rate(self, address):
        now = self.clock()
        with self.lock:
            history = self.rates.setdefault(address, deque())
            while history and history[0] <= now - 60:
                history.popleft()
            if len(history) >= 240:
                reject("rate", 429)
            history.append(now); self.rates.move_to_end(address)
            while len(self.rates) > 4096:
                self.rates.popitem(last=False)

    def __call__(self, environ, start_response):
        try:
            self.rate(environ.get("REMOTE_ADDR", "unknown"))
            method, path = environ["REQUEST_METHOD"], environ["PATH_INFO"]
            length = int(environ.get("CONTENT_LENGTH") or 0)
            if method == 'GET' and path == '/clipboard-live/v1/status':
                if length != 0:
                    reject('size', 413)
                import clipboard_live
                output = encoded(clipboard_live.capabilities())
                start_response('200 OK', [('Content-Type', 'application/json'), ('Content-Length', str(len(output))), ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')])
                return [output]
            maximum = 5 * 1024 * 1024 if path.endswith('/recency') else 3 * 1024 * 1024
            if length < 1 or length > maximum:
                reject("size", 413)
            data = environ["wsgi.input"].read(length)
            if len(data) != length:
                reject()
            value = strict_json(data)
            if method == 'POST' and path == '/clipboard-live/v1/batch':
                import clipboard_live
                result = clipboard_live.batch(self, value)
            elif method == 'POST' and path == '/clipboard-live/v1/revoke':
                import clipboard_live
                result = clipboard_live.revoke(self, value)
            elif method == "POST" and path == "/v1/pairing/claim":
                result = quick_pairing.claim(self,value,environ.get("REMOTE_ADDR","unknown"))
            elif method == "POST" and path == "/v1/groups":
                result = self.register(value)
            else:
                parts = path.strip("/").split("/")
                if len(parts) != 4 or parts[:2] != ["v1", "groups"]:
                    reject("route", 404)
                group = identifier(parts[2])[0]
                if method == "PUT" and parts[3] == "membership":
                    result = self.update(group, value)
                elif method == "POST" and parts[3] == "change":
                    result = self.change_members(group,value)
                elif method == "POST" and parts[3] == "admission":
                    result = self.admit(group,value)
                elif method == "POST" and parts[3] == "events":
                    result = self.push(group, value)
                elif method == "POST" and parts[3] == "rpc":
                    result = self.rpc(group, value)
                elif method == "POST" and parts[3] == "recency":
                    import recent_learning
                    result = recent_learning.handle(self,group,value)
                elif method == "POST" and parts[3] == "keys":
                    result = self.store_key(group, value)
                elif method == "POST" and parts[3] == "pair-challenge":
                    result = self.store_challenge(group, value)
                else:
                    reject("route", 404)
            status, output = 200, encoded(result)
        except RelayError as error:
            status, output = error.status, encoded({"error": error.code})
        except (ValueError, KeyError):
            status, output = 400, encoded({"error": "invalid_or_unavailable"})
        except Exception:
            # Do not hand a body/exception to the WSGI runner's debug logger.
            status, output = 503, encoded({"error": "unavailable"})
        labels = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 410: "Gone", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"}
        start_response(str(status) + " " + labels[status], [("Content-Type", "application/json"), ("Content-Length", str(len(output))), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")])
        return [output]


def main():
    from wsgiref.simple_server import make_server, WSGIRequestHandler
    class QuietHandler(WSGIRequestHandler):
        def log_message(self, *args):
            pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8028)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    app = Relay(args.database)
    with make_server("127.0.0.1", args.port, app, handler_class=QuietHandler) as server:
        if args.ready_file:
            if args.ready_file.parent.resolve() != args.database.parent.resolve() or args.ready_file.exists():
                raise ValueError("Ready file must be new and next to the owned database")
            temporary = args.ready_file.with_suffix(".tmp")
            if temporary.exists():
                raise ValueError("Ready temporary file already exists")
            temporary.write_text(json.dumps({"loopback_port": server.server_port}))
            temporary.rename(args.ready_file)
        print(json.dumps({"loopback_port": server.server_port, "production_server": False}), flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
