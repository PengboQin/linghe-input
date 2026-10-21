"""Synthetic metadata bridge: never needs a production relay, text or keychain."""
import hashlib
import os
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import device_administration as admin


class ArchivePresenceBridgeTests(unittest.TestCase):
    def setUp(self):
        base=Path(__file__).resolve().parents[1]/'build/evidence/activity_presence'
        base.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=base)
        self.path=Path(self.temp.name)/'metadata.sqlite'
        self.now=1792340000
        self.group,self.device=(str(uuid.uuid4()).upper() for _ in range(2))
        self.public=bytes(range(32));self.old=self.now-31*86400
        self.relay=SimpleNamespace(db=sqlite3.connect(':memory:'),clock=lambda:self.now)
        admin.initialize(self.relay.db)
        self.relay.db.execute('INSERT INTO device_profiles VALUES(?,?,?,?,?,?)',(self.group,self.device,'ios',30,self.old,self.public))
        with sqlite3.connect(self.path) as db:
            db.executescript('CREATE TABLE metadata(key TEXT PRIMARY KEY,value BLOB); CREATE TABLE member_activity(group_id TEXT,device_id TEXT,member_key_fingerprint BLOB,last_seen INTEGER,PRIMARY KEY(group_id,device_id));')
            db.execute('INSERT INTO metadata VALUES(?,?)',('archive_schema_version',b'1'))
        self.environment=patch.dict(os.environ,{'PRIVATE_INPUT_ACTIVITY_PRESENCE_DATABASE':str(self.path)})
        self.environment.start()
    def tearDown(self):
        self.environment.stop();self.relay.db.close();self.temp.cleanup()
    def touch(self,when=None,key=None,group=None):
        with sqlite3.connect(self.path) as db:
            db.execute('INSERT INTO member_activity VALUES(?,?,?,?)',(group or self.group,self.device,hashlib.sha256(self.public if key is None else key).digest(),self.now if when is None else when))
    def test_successful_same_key_archive_activity_counts_without_relay_write(self):
        self.touch()
        row=admin.profile(self.relay,self.group,self.device)
        self.assertEqual(row[2],self.now);self.assertFalse(admin.expired(row,self.now))
        self.assertEqual(self.relay.db.execute('SELECT last_seen FROM device_profiles').fetchone()[0],self.old)
    def test_no_opt_in_environment_preserves_original_policy(self):
        self.touch()
        with patch.dict(os.environ,{'PRIVATE_INPUT_ACTIVITY_PRESENCE_DATABASE':''}):
            self.assertTrue(admin.expired(admin.profile(self.relay,self.group,self.device),self.now))
    def test_missing_or_wrong_schema_never_creates_or_grants_activity(self):
        missing=Path(self.temp.name)/'absent.sqlite'
        with patch.dict(os.environ,{'PRIVATE_INPUT_ACTIVITY_PRESENCE_DATABASE':str(missing)}):
            self.assertTrue(admin.expired(admin.profile(self.relay,self.group,self.device),self.now))
        self.assertFalse(missing.exists())
        self.touch()
        with sqlite3.connect(self.path) as db:db.execute('UPDATE metadata SET value=?',(b'2',))
        self.assertTrue(admin.expired(admin.profile(self.relay,self.group,self.device),self.now))
    def test_replaced_key_cannot_reuse_old_activity(self):
        self.touch(key=bytes(reversed(range(32))))
        self.assertTrue(admin.expired(admin.profile(self.relay,self.group,self.device),self.now))
    def test_departed_device_is_not_revived(self):
        self.touch()
        self.relay.db.execute('INSERT INTO departed_devices VALUES(?,?,?)',(self.group,self.device,'removed'))
        self.assertEqual(admin.profile(self.relay,self.group,self.device)[2],self.old)
        from private_input_relay import RelayError
        with self.assertRaises(RelayError):admin.authorized_activity(self.relay,self.group,self.device,self.now)
    def test_other_group_and_future_or_stale_activity_are_ignored(self):
        self.touch(group=str(uuid.uuid4()).upper())
        self.assertEqual(admin.profile(self.relay,self.group,self.device)[2],self.old)
        self.touch(when=self.now+1)
        self.assertEqual(admin.profile(self.relay,self.group,self.device)[2],self.old)
        with sqlite3.connect(self.path) as db:db.execute('UPDATE member_activity SET last_seen=? WHERE group_id=?',(self.old-1,self.group))
        self.assertEqual(admin.profile(self.relay,self.group,self.device)[2],self.old)

if __name__=='__main__':unittest.main()
