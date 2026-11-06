package live.linghe.privateinput;
import java.nio.file.*;import java.nio.charset.StandardCharsets;
public final class RepeatedFrequencyTest {
 public static void main(String[] args)throws Exception {
  Path f=Files.createTempFile("linghe-repeated-frequency-",".txt");
  try{
   Files.write(f,"呃\t1\n得\t50000\n的\t100000\n".getBytes(StandardCharsets.UTF_8));
   CommonExpressionOrder order=new CommonExpressionOrder(f.toFile(),(c,t)->0);
   String[][] rows={{"","","3333","",""},{"0","呃呃呃呃","e e e e"},{"1","得得","de de"},{"2","的的","de de"}};
   String[][] got=order.apply(rows,true,"",r->false);
   if(got[1][1].startsWith("呃"))throw new AssertionError("rare vowels must not lead full common spelling");
   if(!got[3][0].equals("0"))throw new AssertionError("native candidate identity retained");
   got=order.apply(rows,true,"",r->r[0].equals("0"));if(!got[1][0].equals("0"))throw new AssertionError("explicit pin preserved");
   System.out.println("PASS repeated frequency/common spelling, native IDs, pin");
  }finally{Files.delete(f);}
 }
}
