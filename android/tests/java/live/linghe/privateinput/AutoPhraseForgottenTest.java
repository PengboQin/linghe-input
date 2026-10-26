package live.linghe.privateinput;

import android.content.SharedPreferences;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Pure checks for forgotten-term suppression with an in-memory preferences double. */
public final class AutoPhraseForgottenTest {
 private static int checks=0;
 private static void check(boolean ok,String label){if(!ok)throw new AssertionError(label);checks++;}
 static final class Prefs implements SharedPreferences {
  final Map<String,Object> values=new HashMap<>();
  public Map<String,?> getAll(){return values;}
  public String getString(String k,String d){return values.containsKey(k)?(String)values.get(k):d;}
  @SuppressWarnings("unchecked") public Set<String> getStringSet(String k,Set<String> d){return values.containsKey(k)?new HashSet<>((Set<String>)values.get(k)):d;}
  public int getInt(String k,int d){return d;} public long getLong(String k,long d){return d;} public float getFloat(String k,float d){return d;} public boolean getBoolean(String k,boolean d){return d;}
  public boolean contains(String k){return values.containsKey(k);}
  public Editor edit(){return new Editor(){
   final Map<String,Object> pending=new HashMap<>();
   public Editor putString(String k,String v){pending.put(k,v);return this;}
   public Editor putStringSet(String k,Set<String> v){pending.put(k,new HashSet<>(v));return this;}
   public Editor putInt(String k,int v){return this;} public Editor putLong(String k,long v){return this;} public Editor putFloat(String k,float v){return this;} public Editor putBoolean(String k,boolean v){return this;}
   public Editor remove(String k){pending.put(k,null);return this;} public Editor clear(){values.clear();return this;}
   public boolean commit(){apply();return true;}
   public void apply(){for(Map.Entry<String,Object> e:pending.entrySet()){if(e.getValue()==null)values.remove(e.getKey());else values.put(e.getKey(),e.getValue());}}
  };}
  public void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l){}
  public void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l){}
 }
 public static void main(String[] args){
  Prefs prefs=new Prefs();AutoPhrase.Forgotten f=new AutoPhrase.Forgotten(prefs);
  check(!f.suppressed("灵鹤","ling he","v1"),"nothing suppressed initially");
  f.forget("灵鹤","ling he","v1");
  check(f.suppressed("灵鹤","ling he","v1"),"suppressed under the same rank snapshot");
  check(f.suppressed("灵鹤","Ling'He","v1"),"reading normalization matches apostrophe/case");
  check(!f.suppressed("灵鹤","ling he","v2"),"new rank snapshot ends suppression");
  check(!f.suppressed("凌河","ling he","v1"),"other text unaffected");
  f.forget("另送","ling song",null);
  check(f.suppressed("另送","ling song",null),"suppressed without a cloud rank (recent learning)");
  f.selectedAgain("灵鹤","ling he");
  check(!f.suppressed("灵鹤","ling he","v1"),"explicit reselection allows learning again");
  check(f.suppressed("另送","ling song",null),"reselection of one term leaves others");
  f.forget("另送","ling song","v3");f.forget("另送","ling song","v3");
  check(prefs.getStringSet(AutoPhrase.FORGOTTEN,new HashSet<>()).size()==1,"one record per term");
  for(int i=0;i<AutoPhrase.ANNOUNCED_LIMIT+20;i++)f.forget("词"+i,"ci",null);
  check(prefs.getStringSet(AutoPhrase.FORGOTTEN,new HashSet<>()).size()<=AutoPhrase.ANNOUNCED_LIMIT,"bounded storage");
  System.out.println("PASS "+checks+" forgotten-term checks");
 }
}
