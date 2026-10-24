"""Joint capacity contract: signed RPC + production worker, synthetic memory DB.

Pre-fix red evidence is retained under evidence/capacity-p1-20261024 and
capacity-joint-profile-20261024. Production current is expanded-10000/v2;
legacy cases explicitly select the old profile only as boundary fixtures.
"""
import unittest
import hashlib
import json
from unittest.mock import patch
import test_learning as fixture
from activity_archive.service import ArchiveError, encode
from cloud_learning.service import LearningStore, LearningApplication, ALGORITHM
from cloud_learning import capacity


class CapacityFixture(unittest.TestCase):
    tearDown = fixture.LearningTests.tearDown
    envelope = fixture.LearningTests.envelope
    call = fixture.LearningTests.call
    enable = fixture.LearningTests.enable
    event = fixture.LearningTests.event
    ingest = fixture.LearningTests.ingest
    tick = fixture.LearningTests.tick
    pull = fixture.LearningTests.pull

    def setUp(self):
        fixture.LearningTests.setUp(self)
        self.store.close(); self.temp.cleanup()
        self.store = LearningStore(':memory:', clock=lambda: self.now)
        self.app = LearningApplication(self.store, self.authority, clock=lambda: self.now)

    def record(self, i, count=1):
        return {'reading':'rong liang','text':'容量'+str(i),'generation':0,'deleted':False,
                'counts':{self.a:count},'pinned':False,'pinVersion':{'sequence':0,'device':''}}

    def publication(self, records, publication=None, mode='historical_undated'):
        return {'generation':1,'consent_version':1,'installation_id':self.install,
                'producer_id':self.a,'publication_id':publication or fixture.uid(),
                'history_mode':mode,'records':records}

    def legacy_body(self, events):
        return {'generation':1,'consent_version':1,'installation_id':self.install,'events':events}

    def seed_legacy(self):
        for start in range(0,5000,128):
            self.ingest(*[self.event(reading='rong liang',text='容量'+str(i))
                          for i in range(start,min(5000,start+128))])
        while self.call(1,{})['capacity']['pending_events']:
            self.tick(event_limit=4096)

    def seed_components(self):
        for start in range(0,5000,128):
            self.call(6,self.publication([self.record(i) for i in range(start,min(5000,start+128))]))
        self.tick(event_limit=4096)

    def rejected_retry_same_envelope(self, op, body):
        # A failed transaction must not consume nonce or create an exact ACK.
        envelope=self.envelope(op,body)
        for _ in range(2):
            with self.assertRaises(ArchiveError) as caught:
                self.app.dispatch(encode(envelope))
            self.assertEqual((caught.exception.code,caught.exception.status),('term_capacity',503))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_nonces WHERE nonce=?',(envelope['nonce'],)).fetchone()[0],0)

    def snapshot(self, tables):
        return {table:[tuple(row) for row in self.store.db.execute('SELECT * FROM '+table+' ORDER BY rowid')]
                for table in tables}

class MixedCapacityBoundaryTests(CapacityFixture):
    """Explicit legacy fixtures retain old boundary evidence, not a live mode."""
    def setUp(self):
        super().setUp()
        legacy=patch.object(capacity,'profile_for_group',return_value=capacity.LEGACY_5000)
        legacy.start();self.addCleanup(legacy.stop)

    def test_legacy_full_rejects_new_component_but_existing_terms_progress(self):
        self.enable();self.seed_legacy()
        self.assertEqual(len(self.pull()['upserts']),5000)
        before=self.snapshot(['cl_components','cl_producers','cl_publications'])
        self.rejected_retry_same_envelope(6,self.publication([self.record(5000)]))
        self.assertEqual(before,self.snapshot(before))
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),5000)
        # Same key across v1/v2 is one allocation; exact receipt remains stable.
        overlap=self.publication([self.record(0)])
        receipt=self.call(6,overlap)
        self.assertEqual(self.call(6,overlap),receipt)
        self.assertEqual(receipt['changed_records'],1)
        # Changed old row + new row must roll back the whole component batch.
        mixed=self.publication([self.record(0,2),self.record(5000)],mode='incremental')
        before=self.snapshot(['cl_components','cl_producers','cl_publications'])
        self.rejected_retry_same_envelope(6,mixed)
        self.assertEqual(before,self.snapshot(before))
        self.assertEqual(self.call(6,self.publication([self.record(0,2)],mode='incremental'))['changed_records'],1)
        self.ingest(self.event(reading='rong liang',text='容量0'))
        self.tick(event_limit=4096)
        progressed=self.pull()['upserts']
        self.assertEqual(len(progressed),5000)
        self.assertEqual(next(r['weight'] for r in progressed if r['text']=='容量0'),3100)
        # Tombstones remain allocations; a remove is not capacity reclamation.
        self.ingest(self.event('remove',reading='rong liang',text='容量1'))
        self.tick(event_limit=4096)
        self.rejected_retry_same_envelope(6,self.publication([self.record(5000)]))
        model=self.pull()
        self.assertEqual(len(model['upserts']),4999)
        self.assertEqual(len(model['tombstones']),1)
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),5000)

    def test_components_full_rejects_legacy_batch_without_consuming_sequence(self):
        self.enable();self.seed_components()
        old=self.event(reading='rong liang',text='容量0')
        new=self.event(reading='rong liang',text='容量5000')
        before=self.snapshot(['cl_terms','cl_devices','cl_events'])
        self.rejected_retry_same_envelope(4,self.legacy_body([old,new]))
        self.assertEqual(before,self.snapshot(before))
        accepted=self.ingest(old)
        self.assertEqual(accepted['received_device_seq'],1)
        self.assertEqual(accepted['accepted_event_ids'],[old['event_id']])
        self.assertEqual(self.ingest(old),accepted)
        self.rejected_retry_same_envelope(4,self.legacy_body([new]))
        self.assertEqual(self.store.db.execute('SELECT received_seq FROM cl_devices').fetchone()[0],1)
        self.tick(event_limit=4096)
        progressed=self.pull()['upserts']
        self.assertEqual(len(progressed),5000)
        self.assertEqual(next(r['weight'] for r in progressed if r['text']=='容量0'),1100)
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),5000)
        self.assertEqual(self.call(6,self.publication([self.record(0,2)],mode='incremental'))['changed_records'],1)
        self.tick(event_limit=4096)
        self.assertEqual(next(r['weight'] for r in self.pull()['upserts'] if r['text']=='容量0'),2100)

    def test_profile_is_fixed_and_union_scope_keeps_control_keys(self):
        self.enable()
        p=capacity.profile_for_group(self.group,1)
        self.assertEqual((p.identifier,p.version,p.distinct_terms,p.model_terms),('legacy-5000',1,5000,5000))
        self.assertEqual(self.app.capabilities()['max_group_terms'],capacity.CURRENT.distinct_terms)
        self.ingest(self.event('remove'))
        record=dict(self.record(0),reading='dui',text='对',generation=1,deleted=True)
        self.call(6,self.publication([record]))
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),1)
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,2),0)
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.other,1),0)
        with self.assertRaises(RuntimeError):
            capacity.require_term_admission(self.store.db,self.group,1,'dui','对')

    def test_preexisting_overlimit_retains_raw_data_but_requires_later_migration(self):
        self.enable();self.seed_legacy()
        # Old-state fixture bypasses only the new gate during setup. All
        # parsers/receipts/worker remain production, and the gate is restored.
        with patch.object(capacity,'require_term_admission',return_value=None):
            self.call(6,self.publication([self.record(5000)]))
        self.tick(event_limit=4096)
        before=self.snapshot(['cl_terms','cl_events','cl_components','cl_tombstones'])
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),5001)
        with self.assertRaises(ArchiveError) as caught:self.pull()
        self.assertEqual(caught.exception.code,'model_capacity')
        self.rejected_retry_same_envelope(6,self.publication([self.record(5001)]))
        self.assertEqual(before,self.snapshot(before))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_models').fetchone()[0],5001)


class CurrentCapacityBoundaryTests(CapacityFixture):
    def check_model(self, model, expected):
        self.assertEqual({r['text']for r in model['upserts']},expected)
        expected_hash=hashlib.sha256(encode({'generation':1,'algorithm_version':ALGORITHM,
            'upserts':model['upserts'],'watermarks':model['watermarks'],
            'producer_watermarks':model['producer_watermarks']})).hexdigest()
        self.assertEqual(model['model_sha256'],expected_hash)

    def test_current_5001_mixed_model_complete_and_previous_rows_preserved(self):
        self.enable();self.seed_legacy()
        self.assertEqual(capacity.profile_for_group(self.group,1).identifier,'expanded-10000')
        self.assertEqual(self.app.capabilities()['max_group_terms'],10000)
        self.assertEqual(self.call(1,{})['capacity']['max_term_rows'],10000)
        # This is normal current admission, no bypass and no negotiated state.
        receipt=self.call(6,self.publication([self.record(5000)]))
        self.assertEqual(receipt['changed_records'],1)
        self.tick(event_limit=4096)
        tables=['cl_terms','cl_events','cl_components','cl_tombstones','cl_publications','cl_devices']
        before=self.snapshot(tables)
        # Same accepted DB/model shape failed the previous 5000 pull guard.
        with patch.object(capacity,'profile_for_group',return_value=capacity.LEGACY_5000):
            with self.assertRaises(ArchiveError) as caught:self.pull()
            self.assertEqual(caught.exception.code,'model_capacity')
        model=self.pull();self.check_model(model,{'容量'+str(i)for i in range(5001)})
        self.assertEqual(model['watermarks'][0]['device_seq'],5000)
        self.assertEqual(model['producer_watermarks'][0]['component_digest'],receipt['component_digest'])
        self.assertEqual(self.tick(event_limit=4096)['groups_published'],0)
        self.assertEqual(self.pull()['model_sha256'],model['model_sha256'])
        self.assertEqual(before,self.snapshot(tables))
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),5001)
        # Controls survive the new profile and subsequent aggregate passes.
        self.ingest(self.event('remove',reading='rong liang',text='容量1'))
        self.tick(event_limit=4096)
        after_control=self.snapshot(tables)
        fenced=self.pull();self.assertEqual(len(fenced['upserts']),5000)
        self.assertEqual(fenced['tombstones'],[{'reading':'rong liang','text':'容量1','layout':'shared','term_generation':1}])
        self.assertEqual(fenced['watermarks'][0]['device_seq'],5001)
        self.tick(event_limit=4096)
        self.assertEqual(after_control,self.snapshot(tables))
        self.assertEqual(self.pull()['model_sha256'],fenced['model_sha256'])
        print(json.dumps({'case':'current-5001','all5001TermsServed':True,'fullModelSHAVerified':True,
            'sourceRowsPreserved':True,'controlAndWatermarksRetained':True,'productionAccess':False}))

    def test_current_joint_10000_rejects_10001_without_false_ack(self):
        self.enable();self.seed_legacy()
        for start in range(5000,10000,128):
            self.call(6,self.publication([self.record(i)for i in range(start,min(10000,start+128))]))
        self.tick(event_limit=4096)
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),10000)
        self.check_model(self.pull(),{'容量'+str(i)for i in range(10000)})
        # v2 mixed batch rolls back old-key update as well as new allocation.
        before=self.snapshot(['cl_components','cl_producers','cl_publications'])
        self.rejected_retry_same_envelope(6,self.publication([self.record(5000,2),self.record(10000)],mode='incremental'))
        self.assertEqual(before,self.snapshot(before))
        # v1 received sequence/event rows/nonce also remain retryable, not ACKed.
        old=self.event(reading='rong liang',text='容量0')
        new=self.event(reading='rong liang',text='容量10000')
        before=self.snapshot(['cl_terms','cl_events','cl_devices'])
        self.rejected_retry_same_envelope(4,self.legacy_body([old,new]))
        self.assertEqual(before,self.snapshot(before))
        accepted=self.ingest(old)
        self.assertEqual(accepted['received_device_seq'],5001)
        self.assertEqual(self.ingest(old),accepted)
        self.rejected_retry_same_envelope(4,self.legacy_body([new]))
        # A key already present only in v1 may acquire a v2 component at cap.
        self.assertEqual(self.call(6,self.publication([self.record(0)]))['changed_records'],1)
        self.assertEqual(self.call(6,self.publication([self.record(5000,2)],mode='incremental'))['changed_records'],1)
        self.tick(event_limit=4096)
        model=self.pull();self.check_model(model,{'容量'+str(i)for i in range(10000)})
        self.assertEqual(capacity.distinct_term_rows(self.store.db,self.group,1),10000)
        self.assertEqual(next(x['weight']for x in model['upserts']if x['text']=='容量0'),2100)
        self.assertEqual(next(x['weight']for x in model['upserts']if x['text']=='容量5000'),1100)
        print(json.dumps({'case':'current-10000','all10000TermsServed':True,'new10001Rejected':True,
            'nonceSequenceReceiptRollback':True,'existingTermsAdvance':True,'sharedKeyNotDoubleCounted':True,
            'fullModelSHAVerified':True,'productionAccess':False}))


if __name__=='__main__':unittest.main()
