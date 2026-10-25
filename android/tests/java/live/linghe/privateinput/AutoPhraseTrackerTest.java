package live.linghe.privateinput;

/** Pure checks: the tracker pairs a commit with its full reading only for its own selections. */
public final class AutoPhraseTrackerTest {
 private static int checks=0;
 private static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);checks++;}
 public static void main(String[] args){
  AutoPhrase.Tracker t=new AutoPhrase.Tracker();
  t.selected("","灵鹤","ling he");check("ling he".equals(t.committed("灵鹤")),"whole phrase selection");
  check(t.committed("灵鹤")==null,"tracker resets after commit");
  t.selected("","灵","ling");check(t.committed("")==null,"partial selection keeps waiting");
  t.selected("灵","鹤","he");check("ling he".equals(t.committed("灵鹤")),"segmented selections joined");
  t.selected("","灵","ling");t.selected("凌","鹤","he");check(t.committed("灵鹤")==null,"mismatched prefix never guesses");
  t.selected("","灵","ling");check(t.committed("灵河")==null,"commit must equal tracked text");
  t.selected("","灵鹤","");check(t.committed("灵鹤")==null,"missing reading rejected");
  t.selected("","灵","ling");t.reset();t.selected("灵","鹤","he");check(t.committed("灵鹤")==null,"reset breaks continuation");
  t.selected("","灵","ling");t.selected("","鹤","he");check(t.committed("鹤")!=null&&t.committed("灵鹤")==null,"new composition restarts");
  System.out.println("PASS "+checks+" auto-phrase tracker checks");
 }
}
