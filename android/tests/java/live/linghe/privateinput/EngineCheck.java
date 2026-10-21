package live.linghe.privateinput;
import android.app.Instrumentation;import android.os.Bundle;import android.content.Context;import java.io.*;
public final class EngineCheck extends Instrumentation {
 private int passed=0;private long session;private File fixture;
 public void onCreate(Bundle args){super.onCreate(args);start();}
 private void require(boolean ok,String label){if(!ok)throw new AssertionError(label);}
 private void copy(Context c,String name,File out)throws IOException{String[] list=c.getAssets().list(name);if(list!=null&&list.length>0){out.mkdirs();for(String s:list)copy(c,name+"/"+s,new File(out,s));}else{out.getParentFile().mkdirs();try(InputStream in=c.getAssets().open(name);OutputStream to=new FileOutputStream(out)){byte[] buf=new byte[65536];int n;while((n=in.read(buf))>0)to.write(buf,0,n);}}}
 private void type(String text){for(char c:text.toCharArray())NativeCore.key(session,c);}
 private int index(String[][] state,String target){for(int i=1;i<state.length;i++)if(state[i][1].equals(target))return i;return -1;}
 private void pinyin(String code,String target){NativeCore.mode(session,false,true);type(code);String[][] state=NativeCore.snapshot(session);int i=index(state,target);require(i>0,code+" recall");NativeCore.choose(session,Long.parseLong(state[i][0]));state=NativeCore.snapshot(session);require(state[0][1].equals(target),code+" atomic commit");require(state[0][0].isEmpty(),code+" draft ends");passed++;}
 private void remove(File f){if(f.isDirectory()){File[] children=f.listFiles();if(children!=null)for(File c:children)remove(c);}f.delete();}
 public void onStart(){Bundle result=new Bundle();try{
  Context c=getTargetContext();fixture=new File(c.getCacheDir(),"engine-check-"+System.nanoTime());require(fixture.mkdirs(),"new isolated fixture");File data=new File(fixture,"data"),user=new File(fixture,"user");copy(c,"rime",data);user.mkdirs();session=NativeCore.create(data.getAbsolutePath(),user.getAbsolutePath());require(session!=0,"real pinned Rime initialization");
  pinyin("nihao","你好");pinyin("csm","吃什么");pinyin("shih","时候");
  NativeCore.mode(session,true,true);type("64");String before=NativeCore.snapshot(session)[0][2];String[] syllables=NativeCore.syllables(session);int ni=-1;for(int i=0;i<syllables.length;i++)if(syllables[i].equals("ni"))ni=i;require(ni>=0,"nine-key ni reading");NativeCore.filter(session,ni);require(NativeCore.snapshot(session)[0][1].isEmpty(),"filter never commits");NativeCore.delete(session);require(NativeCore.snapshot(session)[0][2].equals(before),"delete undoes reading first");passed++;
  NativeCore.mode(session,true,true);type("64426");String[][] state=NativeCore.snapshot(session);int i=index(state,"你好");require(i>0,"nine-key nihao recall");NativeCore.choose(session,Long.parseLong(state[i][0]));require(NativeCore.snapshot(session)[0][1].equals("你好"),"nine-key atomic commit");passed++;
  NativeCore.mode(session,true,true);require(!NativeCore.hasPending(session),"empty engine has no draft");type("64426");require(NativeCore.hasPending(session),"queued keys recognized before UI snapshot");require(NativeCore.acceptFirst(session),"default candidate accepted");require(NativeCore.snapshot(session)[0][1].equals("你好"),"space after burst chooses current engine candidate");require(!NativeCore.hasPending(session),"space ends draft");require(NativeCore.snapshot(session)[0][1].isEmpty(),"commit drains once");passed++;
  NativeCore.mode(session,true,true);type("64");NativeCore.delete(session);require(NativeCore.hasPending(session),"queued delete preserves earlier key");NativeCore.delete(session);require(!NativeCore.hasPending(session),"queued delete exhausts draft before host delete");passed++;
  NativeCore.mode(session,false,true);type("shi");String[][] first=NativeCore.snapshot(session);require(first.length==97,"initial candidate batch bounded at96");String raw=NativeCore.draft(session)[0];String[][] tail=NativeCore.more(session,96);require(tail.length>0,"candidates continue after96");require(NativeCore.draft(session)[0].equals(raw),"continuation never changes draft");java.util.Set<String> ids=new java.util.HashSet<>();for(int row=1;row<first.length;row++)ids.add(first[row][0]);for(String[] row:tail)require(ids.add(row[0]),"continuation IDs unique");String target=tail[0][1];NativeCore.choose(session,Long.parseLong(tail[0][0]));require(NativeCore.snapshot(session)[0][1].equals(target),"absolute selection after96 commits intended candidate");require(NativeCore.snapshot(session)[0][1].isEmpty(),"continued candidate commits once");passed++;
  NativeCore.mode(session,true,true);type("64426");String[][] source=NativeCore.snapshot(session);int partial=index(source,"你");require(partial>0,"partial word available");NativeCore.choose(session,Long.parseLong(source[partial][0]));String[] protectedDraft=NativeCore.draft(session);require(protectedDraft[1].equals("你")&&NativeCore.hasPending(session),"selected Chinese prefix distinguished from raw pending");NativeCore.more(session,96);require(NativeCore.draft(session)[1].equals("你"),"candidate continuation keeps selected prefix");passed++;
  File language=new File(fixture,"language");language.mkdirs();
  for(String name:new String[]{"pinyin-syllables.txt","nine-lexicon.bin","continuation.bin"})copy(c,name,new File(language,name));
  InputQuality prefixQuality=new InputQuality(language);CommonExpressionOrder essay=new CommonExpressionOrder(new File(data,"essay.txt"),(beforeText,word)->0);
  for(String prefixCode:new String[]{"5468","54684","546842"}){
   NativeCore.mode(session,true,true);type(prefixCode);String[][] nativeRows=NativeCore.snapshot(session);
   java.util.List<InputQuality.Repair> completions=prefixQuality.prefixCompletions(session,nativeRows,false,essay::frequency);
   require(!completions.isEmpty()&&completions.get(0).text.equals("今天"),"cross syllable prefix completion "+prefixCode);
   require(NativeCore.draft(session)[0].equals(prefixCode),"completion private probes preserve all typed digits");
   if(prefixCode.equals("5468"))require(index(nativeRows,"妓女")>0,"legal rarer reading is retained");
   InputQuality.Repair completion=completions.get(0);String[] selected=NativeCore.commitAlternative(session,completion.raw,completion.spelling,completion.text,completion.remainder);
   require(selected.length==2&&selected[1].equals("今天"),"real JNI completes selected phrase exactly once");session=Long.parseLong(selected[0]);
   require(!NativeCore.hasPending(session)&&NativeCore.snapshot(session)[0][1].isEmpty(),"completion has no remaining prefixCode or duplicate native commit");passed++;
  }
  for(String[] exact:new String[][]{{"6364","能","梦"},{"6664","弄","农"},{"968","有","有"},{"5468426","今天","今天"}}){
   NativeCore.mode(session,true,true);type(exact[0]);String[][] nativeRows=NativeCore.snapshot(session);
   require(nativeRows.length>1&&nativeRows[1][1].equals(exact[1]),"strong exact head remains first");
   require(index(nativeRows,exact[2])>0,"same key / repeated-key alternative remains available");
   require(prefixQuality.prefixCompletions(session,nativeRows,false,essay::frequency).isEmpty(),"strong exact head suppresses public prefix promotion");passed++;
  }
  NativeCore.mode(session,true,true);type("5468");InputQuality.Repair stalePrefix=prefixQuality.prefixCompletions(session,NativeCore.snapshot(session),false,essay::frequency).get(0);NativeCore.key(session,'4');
  require(NativeCore.commitAlternative(session,stalePrefix.raw,stalePrefix.spelling,stalePrefix.text,stalePrefix.remainder).length==0&&NativeCore.draft(session)[0].equals("54684"),"stale prefix selection leaves newer raw editable");passed++;
  NativeCore.mode(session,false,true);type("vvvvvv");String[][] unknown=NativeCore.snapshot(session);require(unknown.length==1&&NativeCore.hasPending(session),"unknown spelling fixture stays pending without candidates");String unknownRaw=NativeCore.draft(session)[0];require(!NativeCore.acceptFirst(session),"empty candidate set cannot blindly commit raw spelling");require(NativeCore.draft(session)[0].equals(unknownRaw)&&NativeCore.snapshot(session)[0][1].isEmpty(),"unknown raw remains editable");passed++;
  result.putString("result","Passed");result.putInt("checks",passed);result.putBoolean("isolatedRealRime",true);result.putBoolean("defaultKeyboardChanged",false);
 }catch(Throwable error){result.putString("result","Failed");result.putString("error",error.getClass().getSimpleName()+": "+error.getMessage());}
 finally{if(session!=0)NativeCore.destroy(session);if(fixture!=null)remove(fixture);}
 finish(result.getString("result").equals("Passed")?-1:0,result);
 }
}
