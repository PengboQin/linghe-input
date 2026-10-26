package live.linghe.privateinput;

import java.math.BigInteger;

/** Cross-device forget: a deletion strictly above local and known cloud generations. */
public final class LearningForgetTest {
 private static int checks=0;
 private static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);checks++;}
 public static void main(String[] args)throws Exception{
  LearningModel model=new LearningModel();
  model.setDeviceCount("ling he","灵鹤","device-a",7);
  model.forget("ling he","灵鹤",BigInteger.valueOf(2));
  LearningModel.Entry gone=model.get(LearningModel.Entry.fresh("ling he","灵鹤").id());
  check(gone.deleted,"term deleted");
  check(gone.generation.equals(BigInteger.valueOf(3)),"generation above known cloud generation");
  check(gone.frequency()==0,"counts cleared");
  model.forget("ling cha","另差",BigInteger.ZERO);
  LearningModel.Entry absent=model.get(LearningModel.Entry.fresh("ling cha","另差").id());
  check(absent.deleted&&absent.generation.equals(BigInteger.ONE),"term never learned locally still gets a deletion");
  model.forget("ling cha","另差",null);
  check(model.get(LearningModel.Entry.fresh("ling cha","另差").id()).generation.equals(BigInteger.valueOf(2)),"repeat forget moves forward, never backward");
  model.restore(model.get(LearningModel.Entry.fresh("ling he","灵鹤").id()).id());
  LearningModel.Entry back=model.get(LearningModel.Entry.fresh("ling he","灵鹤").id());
  check(!back.deleted&&back.generation.equals(BigInteger.valueOf(4)),"deliberate relearn uses a newer generation");
  LearningModel known=new LearningModel();known.setDeviceCount("ni hao","你好","device-a",20);known.setPinned("ni hao","你好",true,"device-a");
  known.resetFrequency("ni hao","你好",BigInteger.valueOf(7));known.claimControl("ni hao","你好","device-a");
  LearningModel.Entry reset=known.get("ni hao\u001f你好");check(!reset.deleted&&reset.pinned&&reset.frequency()==0&&reset.generation.intValue()==8,"known reset retains word and pin above cloud generation");
  check(reset.counts.containsKey("device-a"),"reset owns publishable zero component");
  LearningModel relearn=new LearningModel();relearn.forget("ling he","灵鹤",BigInteger.valueOf(7));relearn.claimControl("ling he","灵鹤","device-a");
  relearn.setDeviceCount("ling he","灵鹤","device-b",900);check(relearn.get("ling he\u001f灵鹤").deleted,"old offline counts cannot restore");
  check(relearn.selectedAgain("ling he","灵鹤","device-a",BigInteger.valueOf(8),true),"explicit selection crosses fence");
  check(relearn.get("ling he\u001f灵鹤").generation.intValue()==9&&relearn.get("ling he\u001f灵鹤").frequency()==1,"explicit relearn starts fresh one count");
  check(!relearn.selectedAgain("ling he","灵鹤","device-a",BigInteger.valueOf(9),false),"ordinary selection leaves native counting owner");
  check(!relearn.selectedAgain("ling he","灵鹤","device-a",BigInteger.valueOf(8),true),"old cloud tombstone cannot reset newer local relearn");
  known.forget("ni hao","你好",BigInteger.valueOf(8));known.claimControl("ni hao","你好","device-a");LearningModel.Entry unpinned=known.get("ni hao\u001f你好");check(!unpinned.pinned&&unpinned.pinVersion.sequence.compareTo(reset.pinVersion.sequence)>0,"forget advances pin version to avoid server equivocation");
  System.out.println("PASS "+checks+" learning forget checks");
 }
}
