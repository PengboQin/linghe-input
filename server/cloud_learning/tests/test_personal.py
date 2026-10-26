import unittest
from activity_archive.service import ArchiveError
from test_learning import uid
import test_learning as fixture


class PersonalRecordTests(unittest.TestCase):
    """Personal word/phrase records: server is the single authority (P5)."""
    setUp=fixture.LearningTests.setUp;tearDown=fixture.LearningTests.tearDown
    envelope=fixture.LearningTests.envelope;call=fixture.LearningTests.call;enable=fixture.LearningTests.enable

    def scope(self,actor=None,install=None):
        status=self.call(1,{},actor=actor or self.a)
        return {'generation':status['generation'],'consent_version':(status['consent'] or {'version':0})['version'],'installation_id':install or self.install}

    def record(self,rid=None,seq=1,device=None,deleted=False,text='灵鹤',trigger='ling he',kind='word',created=1):
        rid=rid or uid();device=device or self.a
        return {'id':rid,'entry':{'id':rid,'kind':kind,'text':text,'trigger':trigger},'deleted':deleted,
                'revision':{'sequence':seq,'device':device},'created':{'sequence':created,'device':device}}

    def put(self,records,actor=None,install=None):
        return self.call(8,dict(self.scope(actor,install),records=records),actor=actor or self.a)

    def pull(self,after=0,limit=256,actor=None,install=None):
        return self.call(9,dict(self.scope(actor,install),after_version=after,limit=limit),actor=actor or self.a)

    def both(self):
        self.enable();self.enable(actor=self.b,install=self.install_b)

    def by_id(self,actor=None,install=None):
        return {r['id']:r for r in self.pull(actor=actor,install=install)['records']}

    def test_record_reaches_other_device(self):
        self.both();r=self.record();self.assertEqual(self.put([r])['applied'],1)
        self.assertEqual(self.by_id(actor=self.b,install=self.install_b)[r['id']],r)

    def test_higher_revision_wins_and_stale_is_ignored(self):
        self.both();r=self.record()
        self.put([r]);newer=self.record(r['id'],seq=3,text='灵鹤输入法',device=self.b)
        self.put([newer],actor=self.b,install=self.install_b)
        self.assertEqual(self.put([self.record(r['id'],seq=2)])['applied'],0)
        self.assertEqual(self.by_id()[r['id']]['entry']['text'],'灵鹤输入法')

    def test_deletion_wins_at_equal_sequence(self):
        self.both();r=self.record()
        self.put([self.record(r['id'],seq=2,device=self.b,deleted=True)],actor=self.b,install=self.install_b)
        # Same sequence, other device, not deleted: must not revive.
        self.put([self.record(r['id'],seq=2)])
        self.assertTrue(self.by_id()[r['id']]['deleted'])

    def test_equal_revision_must_be_identical(self):
        self.enable();r=self.record();self.put([r])
        with self.assertRaises(ArchiveError) as caught:self.put([self.record(r['id'],text='别的')])
        self.assertEqual(caught.exception.status,409)
        self.assertEqual(self.put([r])['applied'],0)

    def test_pull_pages_by_version(self):
        self.enable();rows=[self.record(trigger='ling he',text='灵鹤'+str(i)) for i in range(5)];self.put(rows)
        first=self.pull(limit=2);self.assertTrue(first['has_more']);self.assertEqual(len(first['records']),2)
        rest=self.pull(after=first['next_version'],limit=10);self.assertFalse(rest['has_more'])
        self.assertEqual({r['id'] for r in first['records']+rest['records']},{r['id'] for r in rows})
        self.assertEqual(rest['version'],5)

    def test_shortcut_phrase_and_validation(self):
        self.enable()
        self.assertEqual(self.put([self.record(kind='phrase',trigger='dz',text='第一行\n第二行')])['applied'],1)
        for bad in (self.record(trigger='Ling'),self.record(kind='phrase',trigger='a b'),self.record(text='\u0000'),self.record(kind='word',text='a\nb'),
                    dict(self.record(),created={'sequence':5,'device':self.a})):
            with self.assertRaises(ArchiveError):self.put([bad])

    def test_client_bytes_round_trip_and_case_insensitive_identity(self):
        self.enable();r=self.record(device=self.a.lower());r['id']=r['entry']['id']=r['id'].lower()
        self.put([r]);self.assertEqual(self.pull()['records'],[r])
        upper=self.record(r['id'].upper(),seq=1,device=self.a.lower())
        self.assertEqual(self.put([dict(r)])['applied'],0)
        self.assertEqual(len(self.pull()['records']),1)

    def test_requires_consent(self):
        self.enable()
        with self.assertRaises(ArchiveError) as caught:self.put([self.record()],actor=self.b,install=self.install_b)
        self.assertEqual(caught.exception.status,403)


if __name__=='__main__':unittest.main()
