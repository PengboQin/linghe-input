"""One-shot expiry for an existing owned relay database; no HTTP or content logs."""
import argparse
import json
from pathlib import Path
import sqlite3
import stat
import time
from private_input_relay import expire_rows

TABLES = {"groups", "messages", "recipients", "receipts", "nonces", "windows", "key_packages", "pair_sessions", "pairing_tickets", "pairing_attempts", "admissions", "device_profiles", "departed_devices"}
RECENT_TABLES = {"recent_capabilities", "recent_snapshots", "recent_receipts", "recent_nonces", "recent_policy"}
LIVE_TABLES = {"clipboard_live_heads", "clipboard_live_events", "clipboard_live_receipts", "clipboard_live_nonces", "clipboard_live_grants", "clipboard_live_revoked"}

def expire_existing(database, now=None):
    path = Path(database).absolute()
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("Expected a regular existing owned relay database")
    connection = sqlite3.connect(path.as_uri() + "?mode=rw", uri=True, isolation_level=None, timeout=5)
    try:
        connection.execute("PRAGMA trusted_schema=OFF"); connection.execute("PRAGMA secure_delete=ON")
        connection.execute("BEGIN IMMEDIATE")
        try:
            names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")}
            if names not in (TABLES, TABLES | RECENT_TABLES, TABLES | LIVE_TABLES, TABLES | RECENT_TABLES | LIVE_TABLES) or connection.execute("PRAGMA user_version").fetchone()[0] != 0:
                raise ValueError("Unsupported relay schema; no rows removed")
            before = connection.total_changes
            expire_rows(connection, int(time.time()) if now is None else int(now))
            removed = connection.total_changes - before
            connection.execute("COMMIT")
        except Exception:
            connection.execute("ROLLBACK"); raise
        checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        return {"expiredRows": removed, "checkpointBusy": bool(checkpoint[0]), "physicalErasureProven": False}
    finally:
        connection.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(expire_existing(args.database), sort_keys=True))

if __name__ == "__main__":
    main()
