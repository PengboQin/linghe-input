package live.linghe.privateinput;
/** Persisted turn belongs to the current authenticated auto/consent binding.
 * Each turn still pulls at most two messages; no background catch-up loop. */
final class SyncPhasePolicy {
 static int choose(int allowed,boolean automatic,String binding,String savedBinding,int next){
  if(allowed<1||allowed>3)throw new IllegalArgumentException("sync domain mask");
  if(!automatic||(allowed&2)==0)return allowed;
  if((allowed&1)==0)return 2;
  return !binding.isEmpty()&&binding.equals(savedBinding)&&(next==1||next==2)?next:2;
 }
 static int following(int phase){if(phase!=1&&phase!=2)throw new IllegalArgumentException("split phase");return phase==2?1:2;}
 static boolean clipboardDrained(int phase,int received){return phase==2&&received==0;}
}
