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
  System.out.println("PASS "+checks+" learning forget checks");
 }
}
