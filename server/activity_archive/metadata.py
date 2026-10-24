"""Read-only archive liveness proof, never an admission or membership authority."""
from contextlib import closing
import hashlib
from pathlib import Path
import sqlite3
from .capacity import MAX_DATABASE_BYTES
import time
from urllib.parse import quote
import uuid


def latest_authorized_activity(database, group, device, current_member_public, *, now=None):
    """Return server-observed successful-ingest time for same current member key.

    Caller supplies an explicitly configured archive path and independently checks
    current membership/departure. No discovery, creation, writes or future times;
    inaccessible/missing/wrong-schema/invalid-key input returns None. A value alone
    MUST NOT authorize entry, restore a departed device or change group membership.
    """
    try:
        path = Path(database)
        if path.is_symlink() or not path.is_file():
            return None
        resolved = path.resolve()
        if resolved.stat().st_size > MAX_DATABASE_BYTES:
            return None
        group_id, device_id = str(uuid.UUID(group)).upper(), str(uuid.UUID(device)).upper()
        if not isinstance(current_member_public, bytes) or len(current_member_public) != 32:
            return None
        clock = time.time() if now is None else now
        with closing(sqlite3.connect('file:' + quote(str(resolved)) + '?mode=ro', uri=True, timeout=1)) as db:
            schema = db.execute("SELECT value FROM metadata WHERE key='archive_schema_version'").fetchone()
            if not schema or bytes(schema[0]) != b'1':
                return None
            row = db.execute('SELECT member_key_fingerprint,last_seen FROM member_activity WHERE group_id=? AND device_id=?', (group_id, device_id)).fetchone()
            if not row or bytes(row[0]) != hashlib.sha256(current_member_public).digest():
                return None
            if type(row[1]) is not int or not 0 <= row[1] <= clock:
                return None
            return row[1]
    except (OSError, ValueError, TypeError, sqlite3.Error):
        return None
