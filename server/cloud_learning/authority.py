"""Current Relay authorization with per-member admission incarnation.

Archive's historical same-ID/same-key re-admission behavior is not inherited:
consent binds the latest continuous membership interval from signed history.
"""
from contextlib import closing
from dataclasses import dataclass
import hashlib
import sqlite3
from urllib.parse import quote

from activity_archive.service import Identity, RelayMembershipAuthority, fail


@dataclass(frozen=True)
class LearningIdentity(Identity):
    incarnation: str


def fingerprint(who):
    # MemoryAuthority used by isolated callers has no admission history; real
    # deployment always uses LearningMembershipAuthority below.
    incarnation = getattr(who, 'incarnation', '')
    return hashlib.sha256(b'PrivateInput/cloud-learning-member/v1\0' + who.public + incarnation.encode('ascii')).hexdigest()


class LearningMembershipAuthority(RelayMembershipAuthority):
    def resolve(self, group, sender, now):
        who = super().resolve(group, sender, now)
        try:
            from private_input_relay import membership_bytes, strict_json, identifier, b64, RelayError
            with closing(sqlite3.connect('file:' + quote(self.database) + '?mode=ro', uri=True, timeout=3)) as db:
                row = db.execute('SELECT state FROM groups WHERE id=?', (group,)).fetchone()
                if row is None: fail('group', 403)
                state = strict_json(row[0])
                if membership_bytes(state)[2] != who.digest: fail('membership_changed', 409)
                admission = state['revision']
                for item in reversed(state.get('history', []) + [state]):
                    member = next((m for m in item['members'] if identifier(m['device'])[0] == sender), None)
                    if member is None or b64(member['signingPublic'], 32, 32) != who.public or not member['permissions'] & 1:
                        break
                    admission = item['revision']
                # A v1 snapshot with no signed history intentionally binds its
                # revision: a legacy unexplained replacement requires re-consent.
                incarnation = str(admission)
                return LearningIdentity(who.group, who.sender, who.public, who.permissions, who.revision, who.digest, who.members, incarnation)
        except RelayError:
            fail('membership_invalid', 403)
        except sqlite3.Error:
            fail('authority_unavailable', 503)
