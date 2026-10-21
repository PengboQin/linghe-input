package live.linghe.privateinput;
import java.util.*;
public final class RecentLearningOrderingTest {
 static int checks;static void ok(boolean b,String label){checks++;if(!b)throw new AssertionError(label);}
 public static void main(String[] args)throws Exception{
  String[][] rows={{"","","dui","",""},{"1","队","dui"},{"2","对","dui"},{"3","兑","dui"},{"4","对于","dui yu"},{"repair:x","对","dui"},{"custom:x","怼","dui"}};
  RecentLearning model=new RecentLearning();RecentLearning.Policy p=new RecentLearning.Policy(20000);model.record("dui","对","A",30,20000,p);model.record("dui","队","A",50000,null,p);ChoiceMemory memory=new ChoiceMemory();
  String[][] ranked=ChoiceOrder.apply(rows,"",memory,null,1,1,item->false,item->model.score(item.reading,item.text,p));
  ok(ranked[1][1].equals("对"),"recent same-spelling candidate promoted");ok(ranked[4]==rows[4],"different reading/length cannot cross class");ok(ranked[5]==rows[5]&&ranked[6]==rows[6],"repair and explicit personal positions preserved");ok(rows[1][1].equals("队"),"input snapshot not mutated");
  String[][] pins=ChoiceOrder.apply(rows,"",memory,null,1,1,item->item.id.equals("1"),item->model.score(item.reading,item.text,p));ok(pins[1]==rows[1],"pinned user position not displaced");
  String[][] selected=rows.clone();selected[0]=new String[]{"","","dui","","已选"};ok(ChoiceOrder.apply(selected,"",memory,null,1,1,item->false,item->1)==selected,"selected prefix class protected");
  String[][] untouched=ChoiceOrder.apply(rows,"",memory,null,1,1,item->false,item->0);ok(untouched[1]==rows[1]&&untouched[2]==rows[2],"zero evidence stable native order");
  System.out.println("PASS "+checks+" Android eligible candidate ordering checks");
 }
}
