import copy
import hashlib
import unittest
from activity_archive.service import ArchiveError, encode
import test_learning as fixture
from cloud_learning.components import component_digest
from cloud_learning.service import ALGORITHM


class ComponentTests(unittest.TestCase):
    setUp=fixture.LearningTests.setUp;tearDown=fixture.LearningTests.tearDown
    envelope=fixture.LearningTests.envelope;call=fixture.LearningTests.call;enable=fixture.LearningTests.enable
    tick=fixture.LearningTests.tick;pull=fixture.LearningTests.pull;event=fixture.LearningTests.event;ingest=fixture.LearningTests.ingest;error=fixture.LearningTests.error
    def record(self,count=10,producer=None,**extra):
        return {'reading':'dui','text':'对','generation':0,'deleted':False,'counts':{producer or self.a:count},'pinned':False,'pinVersion':{'sequence':0,'device':''}}|extra
    def publish(self,*records,producer=None,actor=None,install=None,mode='historical_undated',publication=None):
        return self.call(6,{'generation':1,'consent_version':1,'installation_id':install or self.install,'producer_id':producer or self.a,'publication_id':publication or fixture.uid(),'history_mode':mode,'records':list(records)},actor=actor)
    def test_native_max_retry_and_full_component_hash(self):
        self.enable();record=self.record();publication=fixture.uid()
        first=self.publish(record,publication=publication)
        retry=self.publish(record,publication=publication)
        self.assertEqual(first,retry);self.assertEqual(first['producer_revision'],1)
        self.assertEqual(first['component_digest'],component_digest(self.a,[record]))
        noop=self.publish(self.record(4));self.assertEqual(noop['producer_revision'],1);self.assertEqual(noop['changed_records'],0)
        self.publish(self.record(11),mode='incremental');self.tick();model=self.pull()
        self.assertEqual(model['upserts'][0]['weight'],2000)
        self.assertEqual(model['producer_watermarks'][0]['producer_revision'],2)
        self.assertEqual(self.tick()['groups_published'],0)
    def test_bootstrap_zero_gets_current_snapshot_not_historical_pages(self):
        self.enable();self.publish(self.record(10));self.tick()
        for count in range(11,22):
            self.publish(self.record(count),mode='incremental');self.tick()
        self.publish(self.record(0,generation=1,deleted=True),mode='incremental');self.tick()
        self.publish(self.record(3,reading='hao',text='好'),mode='incremental');self.tick()
        current=self.call(1,{})['model_version']
        self.assertGreater(current,8)
        snapshot=self.pull(0,limit=1)
        self.assertEqual(snapshot['to_version'],current);self.assertFalse(snapshot['has_more'])
        self.assertEqual([x['text'] for x in snapshot['upserts']],['好'])
        self.assertEqual(snapshot['tombstones'],[{'reading':'dui','text':'对','layout':'shared','term_generation':1}])
        self.assertEqual(snapshot['producer_watermarks'][0]['producer_revision'],current)
        self.assertEqual(snapshot['model_sha256'],self.store.model_hash(1,snapshot['upserts'],snapshot['watermarks'],snapshot['producer_watermarks']))
        page=self.pull(1,limit=1)
        self.assertEqual(page['to_version'],2);self.assertTrue(page['has_more'])
        self.assertEqual(page['upserts'][0]['text'],'对')
    def test_historical_undated_not_fresh_events_and_no_archive_training(self):
        self.enable();self.publish(self.record(20));self.tick()
        self.assertEqual(self.pull()['upserts'][0]['weight'],2000)
        self.assertEqual(self.store.db.execute('SELECT undated_count FROM cl_components').fetchone()[0],20)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_events').fetchone()[0],0)
    def test_controls_merge_shared_lexeme_across_producers_and_old_generation(self):
        self.enable();self.enable(actor=self.b,install=self.install_b)
        self.publish(self.record(10));self.publish(self.record(20,producer=self.b),producer=self.b,actor=self.b,install=self.install_b)
        self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],3000)
        self.publish(self.record(0,generation=1),mode='incremental');self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],0)
        self.publish(self.record(100,producer=self.b),producer=self.b,actor=self.b,install=self.install_b,mode='incremental');self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],0)
        self.publish(self.record(0,generation=1,deleted=True),mode='incremental');self.tick();self.assertEqual(self.pull()['tombstones'][0]['term_generation'],1)
        self.publish(self.record(1,generation=2),mode='incremental');self.tick();model=self.pull()
        self.assertEqual(model['upserts'][0]['weight'],1000);self.assertEqual(model['upserts'][0]['term_generation'],2)
    def test_pin_version_independent_of_frequency_generation(self):
        self.enable();self.enable(actor=self.b,install=self.install_b)
        self.publish(self.record(10));self.publish(self.record(0,producer=self.b,pinned=True,pinVersion={'sequence':10,'device':self.b}),producer=self.b,actor=self.b,install=self.install_b)
        self.publish(self.record(0,generation=1),mode='incremental');self.tick();self.assertTrue(self.pull()['upserts'][0]['pinned'])
        self.publish(self.record(0,generation=1,pinned=False,pinVersion={'sequence':11,'device':self.a}),mode='incremental');self.tick();self.assertFalse(self.pull()['upserts'][0]['pinned'])
    def test_producer_alias_owned_and_peer_count_rejected(self):
        self.enable();self.enable(actor=self.b,install=self.install_b);self.publish(self.record())
        with self.assertRaises(ArchiveError) as caught:self.publish(self.record(),producer=self.a,actor=self.b,install=self.install_b)
        self.assertEqual(caught.exception.code,'producer_owned_by_other_device')
        with self.assertRaises(ArchiveError) as caught:self.publish(self.record(counts={self.a:1,self.b:2}))
        self.assertEqual(caught.exception.code,'producer_counts')
        alias=fixture.uid();self.publish(self.record(producer=alias),producer=alias)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_producers').fetchone()[0],2)
    def test_first_publish_requires_explicit_undated_baseline(self):
        self.enable()
        with self.assertRaises(ArchiveError) as caught:self.publish(self.record(),mode='incremental')
        self.assertEqual(caught.exception.code,'producer_bootstrap_required')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_producers').fetchone()[0],0)
        self.publish();self.publish(self.record(1),mode='incremental');self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],1000)
    def test_conflicting_publication_and_control_metadata_fail_closed(self):
        self.enable();publication=fixture.uid();self.publish(self.record(),publication=publication)
        with self.assertRaises(ArchiveError) as caught:self.publish(self.record(11),publication=publication)
        self.assertEqual(caught.exception.code,'publication_conflict')
        with self.assertRaises(ArchiveError) as caught:self.publish(self.record(pinned=True))
        self.assertEqual(caught.exception.code,'pin_version_conflict')
        self.assertEqual(self.store.db.execute('SELECT revision FROM cl_producers').fetchone()[0],1)
    def test_aggregate_watermark_is_not_upload_receipt(self):
        self.enable();receipt=self.publish(self.record());self.assertEqual(self.pull()['producer_watermarks'],[])
        self.tick();model=self.pull();self.assertEqual(model['producer_watermarks'][0]['component_digest'],receipt['component_digest'])
        expected=hashlib.sha256(encode({'generation':1,'algorithm_version':ALGORITHM,'upserts':model['upserts'],'watermarks':model['watermarks'],'producer_watermarks':model['producer_watermarks']})).hexdigest()
        self.assertEqual(expected,model['model_sha256'])
    def test_member_revocation_excludes_its_components_but_retains_original(self):
        self.enable();self.publish(self.record());self.tick()
        self.authority.put(self.group,{self.b:self.members[self.b]},revision=2);self.tick();self.enable(actor=self.b,install=self.install_b)
        model=self.call(5,{'generation':1,'from_version':0},actor=self.b)
        self.assertEqual(model['upserts'],[]);self.assertEqual(model['producer_watermarks'],[])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_components').fetchone()[0],1)
    def test_op4_layout_only_source_and_shared_control(self):
        self.enable();self.ingest(self.event(layout='pinyin26'),self.event(layout='t9'));self.tick()
        model=self.pull();self.assertEqual(len(model['upserts']),1);self.assertEqual(model['upserts'][0]['layout'],'shared');self.assertEqual(model['upserts'][0]['weight'],2000)
        self.ingest(self.event('reset',layout='pinyin26'));self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],0)
        result=self.ingest(self.event(layout='t9'));self.assertEqual(result['rejected_event_ids'][0]['reason'],'term_generation_stale')
    def test_hourly_decay_changes_model_not_component_digest(self):
        self.enable();receipt=self.publish(self.record());self.tick();self.now+=3600;self.tick();model=self.pull()
        self.assertLess(model['upserts'][0]['weight'],1000);self.assertEqual(model['producer_watermarks'][0]['component_digest'],receipt['component_digest'])
    def test_idle_ten_minute_batch_does_not_publish_decay_version(self):
        self.enable();self.publish(self.record());self.tick();version=self.pull()['to_version']
        self.now+=600;self.assertEqual(self.tick()['groups_published'],0)
        self.assertEqual(self.pull()['to_version'],version)
    def test_empty_control_normalized_for_native_digest(self):
        self.enable();record=self.record(counts={},generation=1);receipt=self.publish(record)
        self.assertEqual(receipt['component_digest'],component_digest(self.a,[dict(record,counts={self.a:0})]))
        self.tick();self.assertEqual(self.pull()['upserts'][0]['weight'],0)
    def bootstrap(self,producer=None,actor=None,install=None,consent=1,group=None):
        return self.call(7,{'generation':1,'consent_version':consent,'installation_id':install or self.install,'producer_id':producer or self.a},actor=actor,group=group)
    def test_unbound_bootstrap_is_empty_and_does_not_claim_producer(self):
        self.enable();result=self.bootstrap()
        self.assertFalse(result['exists']);self.assertEqual(result['records'],[]);self.assertEqual(result['producer_revision'],0)
        self.assertEqual(result['component_digest'],component_digest(self.a,[]))
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM cl_producers').fetchone()[0],0)
    def test_own_bootstrap_full_sorted_hash_does_not_mutate_components(self):
        self.enable();self.publish(self.record(20),self.record(7,reading='tao bao',text='淘宝'))
        before=tuple(self.store.db.execute('SELECT * FROM cl_producers').fetchone())
        result=self.bootstrap();self.assertTrue(result['exists']);self.assertEqual(result['producer_revision'],1)
        self.assertEqual(result['records'],sorted(result['records'],key=lambda r:(r['reading'],r['text'])))
        self.assertEqual(result['component_digest'],component_digest(self.a,result['records']))
        self.assertEqual(tuple(self.store.db.execute('SELECT * FROM cl_producers').fetchone()),before)
    def test_other_device_and_other_group_cannot_bootstrap_own_producer(self):
        self.enable();self.enable(actor=self.b,install=self.install_b);self.publish(self.record())
        with self.assertRaises(ArchiveError) as caught:self.bootstrap(actor=self.b,install=self.install_b)
        self.assertEqual(caught.exception.code,'producer_owned_by_other_device')
        self.enable(actor=self.c,group=self.other)
        other=self.bootstrap(actor=self.c,group=self.other)
        self.assertFalse(other['exists']);self.assertEqual(other['records'],[])
    def test_old_local_state_bootstraps_then_stale_counters_take_max(self):
        self.enable();self.publish(self.record(20));full=self.bootstrap();self.assertEqual(full['records'][0]['counts'][self.a],20)
        result=self.publish(self.record(2),mode='incremental')
        self.assertEqual(result['component_digest'],full['component_digest']);self.assertEqual(result['changed_records'],0)
        newer=self.publish(self.record(21),mode='incremental')
        self.assertNotEqual(newer['component_digest'],full['component_digest'])
    def test_new_consent_reads_then_empty_publication_refreshes_binding(self):
        self.enable();self.publish(self.record(20));self.tick();self.enable()
        full=self.bootstrap(consent=2);self.assertTrue(full['exists'])
        self.assertEqual(self.store.db.execute('SELECT consent_version FROM cl_producers').fetchone()[0],1)
        self.call(6,{'generation':1,'consent_version':2,'installation_id':self.install,'producer_id':self.a,'publication_id':fixture.uid(),'history_mode':'historical_undated','records':[]})
        self.assertEqual(self.store.db.execute('SELECT consent_version FROM cl_producers').fetchone()[0],2)
        self.tick();self.assertEqual(self.pull()['producer_watermarks'][0]['component_digest'],full['component_digest'])

if __name__=='__main__':unittest.main()
