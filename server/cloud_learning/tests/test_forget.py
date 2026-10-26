import unittest
import test_learning as fixture
import test_components as components


class ForgetTests(unittest.TestCase):
    """Undo/forget is one server-side control: a higher term generation with deleted=true.

    Covers the case the device that forgets never published the term, stale producers,
    concurrent controls, bootstrap snapshots and deliberate relearning.
    """
    setUp=fixture.LearningTests.setUp;tearDown=fixture.LearningTests.tearDown
    envelope=fixture.LearningTests.envelope;call=fixture.LearningTests.call;enable=fixture.LearningTests.enable
    tick=fixture.LearningTests.tick;pull=fixture.LearningTests.pull
    record=components.ComponentTests.record;publish=components.ComponentTests.publish

    def both(self):
        self.enable();self.enable(actor=self.b,install=self.install_b)

    def publish_b(self,record,mode='incremental'):
        return self.publish(record,producer=self.b,actor=self.b,install=self.install_b,mode=mode)

    def forget_from_a(self,term_generation):
        # Device A never published this term: control-only entry with its own zero counter.
        return self.publish(self.record(0,generation=term_generation+1,deleted=True),mode='historical_undated')

    def current(self):
        model=self.pull();terms={(x['reading'],x['text']):x for x in model['upserts']}
        stones={(x['reading'],x['text']):x for x in model['tombstones']}
        return terms,stones

    def test_forget_by_device_that_never_learned_the_term(self):
        self.both();self.publish_b(self.record(20,producer=self.b),mode='historical_undated');self.tick()
        terms,_=self.current();self.assertIn(('dui','对'),terms);generation=terms[('dui','对')]['term_generation']
        self.forget_from_a(generation);self.tick()
        terms,stones=self.current()
        self.assertNotIn(('dui','对'),terms)
        self.assertEqual(stones[('dui','对')]['term_generation'],generation+1)

    def test_stale_producer_cannot_revive_forgotten_term(self):
        self.both();self.publish_b(self.record(20,producer=self.b),mode='historical_undated');self.tick()
        self.forget_from_a(0);self.tick()
        # B has not seen the tombstone yet and keeps counting at the old generation.
        self.publish_b(self.record(500,producer=self.b));self.tick()
        terms,stones=self.current()
        self.assertNotIn(('dui','对'),terms);self.assertIn(('dui','对'),stones)

    def test_concurrent_reset_and_forget_at_same_generation_deletion_wins(self):
        self.both();self.publish(self.record(10),mode='historical_undated');self.publish_b(self.record(10,producer=self.b),mode='historical_undated');self.tick()
        self.publish(self.record(0,generation=1,deleted=True),mode='incremental')
        self.publish_b(self.record(3,producer=self.b,generation=1))
        self.tick();terms,stones=self.current()
        self.assertNotIn(('dui','对'),terms);self.assertEqual(stones[('dui','对')]['term_generation'],1)

    def test_bootstrap_snapshot_carries_forget_and_other_terms_untouched(self):
        self.both();self.publish_b(self.record(20,producer=self.b),mode='historical_undated')
        self.publish_b(self.record(5,producer=self.b,reading='hao',text='好'));self.tick()
        self.forget_from_a(0);self.tick()
        snapshot=self.pull(0)
        self.assertEqual([x['text'] for x in snapshot['upserts']],['好'])
        self.assertEqual(snapshot['tombstones'],[{'reading':'dui','text':'对','layout':'shared','term_generation':1}])

    def test_deliberate_relearn_after_forget_needs_new_generation(self):
        self.both();self.publish_b(self.record(20,producer=self.b),mode='historical_undated');self.tick()
        self.forget_from_a(0);self.tick()
        self.publish_b(self.record(1,producer=self.b,generation=2));self.tick()
        terms,stones=self.current()
        self.assertEqual(terms[('dui','对')]['term_generation'],2);self.assertGreater(terms[('dui','对')]['weight'],0)
        self.assertNotIn(('dui','对'),stones)

    def test_forget_is_idempotent_on_retry(self):
        self.both();self.publish_b(self.record(20,producer=self.b),mode='historical_undated');self.tick()
        publication=fixture.uid()
        first=self.publish(self.record(0,generation=1,deleted=True),mode='historical_undated',publication=publication)
        retry=self.publish(self.record(0,generation=1,deleted=True),mode='historical_undated',publication=publication)
        self.assertEqual(first,retry);self.tick()
        self.assertEqual(self.tick()['groups_published'],0)


if __name__=='__main__':unittest.main()
