package live.linghe.privateinput;

import android.app.Instrumentation;
import android.os.Bundle;
import android.util.AtomicFile;
import java.io.File;
import java.util.List;
import java.util.UUID;

/** Synthetic saved-vocabulary projection checks; no product data, engine or network. */
public final class LearnedVocabularyInstrumentation extends Instrumentation {
 private int checks;private File base;
 private void require(boolean ok,String why){checks++;if(!ok)throw new AssertionError(why);}
 private static void remove(File file){File[] children=file.listFiles();if(children!=null)for(File child:children)remove(child);file.delete();}
 private File root(String name)throws Exception{if(base==null){base=new File(getTargetContext().getCacheDir(),"learned-vocab-"+UUID.randomUUID());base.mkdirs();}File root=new File(base,name);root.mkdirs();new File(root,"Shared").mkdirs();return root;}
 private static void write(File file,String text,int maximum)throws Exception{AppFiles.write(new AtomicFile(file),text,maximum);}
 private LearningModel model()throws Exception{return new LearningModel(LearningCapacityProfiles.EXPANDED_10000);}
 private List<LearningModel.Entry> read(File root)throws Exception{return LearnedVocabularyProjection.read(root,new File(root,"Shared"));}
 @Override public void onCreate(Bundle arguments){super.onCreate(arguments);start();}
 @Override public void onStart(){Bundle result=new Bundle();File work=null;try{
  work=root("all");
  LearningModel normal=model();normal.setDeviceCount("ling he","灵鹤","a",7);normal.setDeviceCount("ni hao","你好","a",3);write(new File(work,"Shared/learning-v1.json"),normal.export(),LearningModel.MAX_BYTES);
  List<LearningModel.Entry> rows=read(work);require(rows.size()==2,"normal rows");require(rows.get(0).text.equals("灵鹤")&&rows.get(0).frequency()==7,"counts and order");require(rows.get(1).text.equals("你好"),"second row");

  File hiddenRoot=root("hidden");LearningModel hidden=model();hidden.setDeviceCount("shan chu","删除","a",2);hidden.forget("shan chu","删除",null);hidden.setDeviceCount("ling ci","零次","a",0);hidden.setPinned("zhi ding","置顶",true,"a");write(new File(hiddenRoot,"Shared/learning-v1.json"),hidden.export(),LearningModel.MAX_BYTES);
  List<LearningModel.Entry> hiddenRows=read(hiddenRoot);require(hiddenRows.size()==1&&hiddenRows.get(0).text.equals("置顶"),"deleted and zero unpinned hidden; pinned zero kept");

  File mergeRoot=root("merge");LearningModel shared=model();shared.setDeviceCount("ling he","灵鹤","a",2);write(new File(mergeRoot,"Shared/learning-v1.json"),shared.export(),LearningModel.MAX_BYTES);
  LearningModel same=model();same.setDeviceCount("ling he","灵鹤","a",2);RimeCheckpoint checkpoint=new RimeCheckpoint();checkpoint.model=same;write(new File(mergeRoot,"learning-checkpoint-v1.json"),checkpoint.encode(),RimeCheckpoint.MAX_STATE_BYTES);
  require(read(mergeRoot).get(0).frequency()==2,"same device does not double count");
  LearningModel other=model();other.setDeviceCount("ling he","灵鹤","b",3);checkpoint.model=other;write(new File(mergeRoot,"learning-checkpoint-v1.json"),checkpoint.encode(),RimeCheckpoint.MAX_STATE_BYTES);
  require(read(mergeRoot).get(0).frequency()==5,"different device counters merge");

  File deleteRoot=root("delete");LearningModel active=model();active.setDeviceCount("ling he","灵鹤","a",9);write(new File(deleteRoot,"Shared/learning-v1.json"),active.export(),LearningModel.MAX_BYTES);
  LearningModel tomb=model();tomb.forget("ling he","灵鹤",java.math.BigInteger.ZERO);checkpoint.model=tomb;write(new File(deleteRoot,"learning-checkpoint-v1.json"),checkpoint.encode(),RimeCheckpoint.MAX_STATE_BYTES);
  require(read(deleteRoot).isEmpty(),"newer checkpoint deletion wins over shared active");

  File relearnRoot=root("relearn");LearningModel relearn=model();relearn.setDeviceCount("ling he","灵鹤","a",4);relearn.forget("ling he","灵鹤",java.math.BigInteger.ZERO);write(new File(relearnRoot,"Shared/learning-v1.json"),relearn.export(),LearningModel.MAX_BYTES);require(read(relearnRoot).isEmpty(),"forgotten row hidden");require(relearn.selectedAgain("ling he","灵鹤","a",java.math.BigInteger.ZERO,true),"explicit reselection restores learning");write(new File(relearnRoot,"Shared/learning-v1.json"),relearn.export(),LearningModel.MAX_BYTES);List<LearningModel.Entry> relearned=read(relearnRoot);require(relearned.size()==1&&relearned.get(0).text.equals("灵鹤")&&relearned.get(0).frequency()==1,"relearned row is visible with count one");

  File searchRoot=root("search");LearningModel search=model();search.setDeviceCount("ling he","灵鹤","a",2);search.setDeviceCount("ni hao","你好","a",1);write(new File(searchRoot,"Shared/learning-v1.json"),search.export(),LearningModel.MAX_BYTES);
  require(LearnedVocabularyProjection.filter(read(searchRoot),"灵鹤").size()==1,"Chinese search");
  require(LearnedVocabularyProjection.filter(read(searchRoot),"NI HAO").get(0).text.equals("你好"),"pinyin search case insensitive");
  require(LearnedVocabularyProjection.filter(read(searchRoot),"zzz").isEmpty(),"no match");

  File sortRoot=root("sort");LearningModel sort=model();sort.setDeviceCount("yi","乙","a",1);sort.setDeviceCount("jia","甲","a",1);write(new File(sortRoot,"Shared/learning-v1.json"),sort.export(),LearningModel.MAX_BYTES);
  List<LearningModel.Entry> sorted=read(sortRoot);require(sorted.get(0).text.equals("甲")&&sorted.get(1).text.equals("乙"),"stable equal-frequency order");

  File badRoot=root("bad");write(new File(badRoot,"Shared/learning-v1.json"),"not json",LearningModel.MAX_BYTES);boolean rejected=false;try{read(badRoot);}catch(Exception expected){rejected=true;}require(rejected,"bad shared snapshot is an error");
  write(new File(badRoot,"Shared/learning-v1.json"),normal.export(),LearningModel.MAX_BYTES);write(new File(badRoot,"learning-checkpoint-v1.json"),"not json",RimeCheckpoint.MAX_STATE_BYTES);boolean checkpointRejected=false;try{read(badRoot);}catch(Exception expected){checkpointRejected=true;}require(checkpointRejected,"bad checkpoint fails closed instead of showing older shared rows");

  result.putString("result","Passed");result.putInt("checks",checks);finish(-1,result);
 }catch(Throwable failure){result.putString("result","Failed");result.putString("error",failure.getClass().getSimpleName()+": "+failure.getMessage());result.putInt("checks",checks);finish(1,result);}finally{if(base!=null)remove(base);}}
}
