"""Offline maintenance: no HTTP exposure and no content printed."""
import argparse
from pathlib import Path
import shutil
import sqlite3

from .service import ArchiveStore


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    expire = commands.add_parser('expire', help='Run all tenant retention policies')
    expire.add_argument('--database', required=True)
    backup = commands.add_parser('backup', help='Consistent database snapshot; keep latest deletion ledger separately')
    backup.add_argument('--database', required=True)
    backup.add_argument('--destination', required=True)
    restore = commands.add_parser('restore', help='SERVICE MUST BE STOPPED; replay latest erasure ledger before serving')
    restore.add_argument('--database', required=True)
    restore.add_argument('--snapshot', required=True)
    restore.add_argument('--ledger', required=True, help='Latest independently preserved ledger, not snapshot-era copy')
    options = parser.parse_args(argv)
    path = Path(options.database)
    if options.command == 'restore':
        source = Path(options.snapshot)
        ledger = Path(options.ledger)
        if not source.is_file() or not ledger.is_file() or path.exists():
            parser.error('snapshot+latest ledger must exist; restore destination must be a NEW path')
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(source, path)
        path.chmod(0o600)
        shutil.copyfile(ledger, str(path) + '.erase-ledger.jsonl')
        Path(str(path) + '.erase-ledger.jsonl').chmod(0o600)
        # Constructor validates/replays the ledger before readiness. Any corrupt
        # ledger aborts; deployer must not switch service to an unverified path.
        store = ArchiveStore(path)
        store.close()
        print('Restore verified; newest tombstones replayed. Switch service path only after offline review.')
        return
    if not path.is_file():
        parser.error('existing activity database required')
    store = ArchiveStore(path)
    try:
        if options.command == 'backup':
            destination = Path(options.destination)
            if destination.exists():
                parser.error('backup destination must be new')
            store.backup(destination)
            ledger = Path(str(path) + '.erase-ledger.jsonl')
            destination_ledger = Path(str(destination) + '.erase-ledger.jsonl')
            if ledger.exists():
                shutil.copyfile(ledger, destination_ledger)
            else:
                destination_ledger.touch(mode=0o600)
            destination_ledger.chmod(0o600)
            print('Consistent snapshot created. Continue preserving the LIVE latest deletion ledger separately.')
        else:
            with store.lock:
                groups = [r[0] for r in store.db.execute('SELECT group_id FROM archive_groups')]
                for group in groups:
                    store.expire(group)
            print('Retention maintenance complete; no plaintext emitted.')
    finally:
        store.close()


if __name__ == '__main__':
    main()
