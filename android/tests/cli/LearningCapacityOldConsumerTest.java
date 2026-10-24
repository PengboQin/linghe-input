package live.linghe.privateinput;
import java.nio.file.*;import java.nio.charset.StandardCharsets;import org.json.JSONObject;
/** Run with this class only + the installed50APK, never candidate model classes. */
public final class LearningCapacityOldConsumerTest {
 interface Checked{void run()throws Exception;}
 static int checks;static void rejected(Checked action)throws Exception{boolean failed=false;try{action.run();}catch(Exception expected){failed=true;}checks++;if(!failed)throw new AssertionError("Old consumer accepted an expanded format");}
 static String read(Path dir,String name)throws Exception{return new String(Files.readAllBytes(dir.resolve(name)),StandardCharsets.UTF_8);}
 public static void main(String[]args)throws Exception{
  Path dir=Paths.get(args[0]);rejected(()->new LearningModel().merge(read(dir,"expanded-model-small.json")));
  rejected(()->LearningModel.fromState(new JSONObject(read(dir,"expanded-model-state-small.json"))));
  rejected(()->RimeCheckpoint.decode(read(dir,"expanded-checkpoint.json")));
  rejected(()->RecentLearningStore.decode(read(dir,"expanded-recent-small.json"),new RecentLearning.Policy(20000)));
  LearningModel old=new LearningModel();old.merge(read(dir,"legacy-model.json"));if(old.entries().size()!=5000)throw new AssertionError("Legacy archive no longer readable");checks++;
  if(RecentLearningStore.decode(read(dir,"legacy-recent.json"),new RecentLearning.Policy(20000)).model.entries().size()!=5000)throw new AssertionError("Legacy recency unreadable");checks++;
  System.out.println("{\"checks\":"+checks+",\"oldInstalled50ConsumerUsed\":true,\"allExpandedRejected\":true,\"legacyReadable\":true,\"syntheticOnly\":true}");
 }
}
