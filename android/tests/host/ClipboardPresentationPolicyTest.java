package live.linghe.privateinput;

public final class ClipboardPresentationPolicyTest {
 private static int checks;
 private static void require(boolean ok,String label){checks++;if(!ok)throw new AssertionError(label);}
 private static boolean idle(ClipboardPresentationPolicy p,long now){return p.idle(true,false,0,false,false,false,now);}
 public static void main(String[] args){
  ClipboardPresentationPolicy p=new ClipboardPresentationPolicy();
  require(idle(p,0),"fresh idle editor may show a new copy");
  p.edited(1000);
  require(!idle(p,1000)&&!idle(p,1699),"literal digits and English remain busy after direct commit");
  require(idle(p,1700),"new observation after the idle window may present");
  require(!idle(p,999),"clock rollback never releases recent-input protection");
  require(!p.idle(true,true,0,false,false,false,2000),"pinyin composition is never replaced");
  require(!p.idle(true,false,1,false,false,false,2000),"queued native key protects before composition exists");
  require(!p.idle(true,false,0,true,false,false,2000),"finger down on candidate or key blocks incoming presentation");
  require(!p.idle(true,false,0,false,true,false,2000),"unfinished English word remains protected");
  require(!p.idle(false,false,0,false,false,false,2000),"sensitive invisible or unknown editor is excluded");
  require(!p.idle(true,false,0,false,false,true,2000),"continuous delete keeps suggestions cancelled");
  ClipboardCandidateState state=new ClipboardCandidateState();
  ClipboardCandidateState.Value old=ClipboardCandidateState.Value.create("old copy",11,true);
  ClipboardCandidateState.Value fresh=ClipboardCandidateState.Value.create("new copy",12,true);
  state.offer(1,old);
  require(state.visible(1,true,false)==old,"first idle copy displays in existing candidate line");
  state.offer(1,fresh);
  require(state.visible(1,true,false)==fresh&&!state.matches(1,old.id),"idle new copy replaces old preview without a history list");
  state.dismiss(1);
  require(!state.matches(1,fresh.id)&&state.visible(1,true,false)==null,"explicit typing cancels a copy even before it becomes visible");
  state.offer(1,fresh);
  require(state.visible(1,true,false)==null,"same pending callback cannot revive cancelled copy");
  PredictionSuppression language=new PredictionSuppression();language.deleting();p.edited(2100);
  require(language.suppressed()&&!idle(p,2799),"recent deletion suppresses new copies and language predictions independently");
  ClipboardCandidateState.Value afterDelete=ClipboardCandidateState.Value.create("new distinct copy after delete",13,true);
  require(language.suppressed()&&idle(p,2800),"new copy becomes eligible after 700ms while language predictions stay suppressed");
  state.offer(1,afterDelete);
  require(state.visible(1,true,false)==afterDelete&&state.matches(1,afterDelete.id),"new distinct copy remains both visible and selectable after deletion");
  state.dismiss(1);state.offer(1,afterDelete);
  require(state.visible(1,true,false)==null,"dismissing that new copy also prevents its later callback revival");
  p.edited(3000);boolean observedIdle=idle(p,3000);
  // This is the service admission contract: claim the copy once on IO, then
  // re-check both arrival admission and current edit/pressed safety on callback.
  boolean callbackMayPresent=observedIdle&&idle(p,5000);
  require(!callbackMayPresent,"busy arrival is discarded even when IO finishes after typing stops");
  boolean firstArrivalIdle=idle(p,5000);p.edited(5001);
  require(firstArrivalIdle&&!idle(p,5002),"input while receipt IO waits cancels the formerly idle presentation");
  AutoClipboardState delivery=new AutoClipboardState();delivery.establishEmptyBaseline("empty");
  AutoClipboardState.Pass cold=delivery.begin("synthetic-group");delivery.drained(cold);
  AutoClipboardState.Pass pass=delivery.begin("synthetic-group");
  require(delivery.accept(pass,"new-remote-while-typing",false,false),"UI typing suppression does not pause independent clipboard delivery");
  delivery.observe("new-local","locally copied replacement",false);
  require(!delivery.accept(pass,"late-remote",false,false),"local copy after network request wins over late remote delivery");
  System.out.println("PASS clipboard UI contracts="+checks+" systemClipboard=false network=false");
 }
}
