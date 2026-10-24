package live.linghe.privateinput;
import java.io.*;
public final class LearningTinyDiagnosticsTest {
 public static void main(String[]args){LearningTinyDiagnostics d=new LearningTinyDiagnostics();d.event(1,1,1);d.event(2,2,0);d.began();d.apply(16,0,0,0,false,false,false);d.event(10,0,0);d.event(2,2,8);StringWriter buffer=new StringWriter();d.snapshot().print(new PrintWriter(buffer));String text=buffer.toString();if(!text.contains("pre_bits=16")||!text.contains("apply_attempt=1")||!text.contains("schedule_bits=8")||!text.contains("applied=false"))throw new AssertionError();for(String line:text.split("\\n"))if(!line.matches("[a-z0-9_= ]*"))throw new AssertionError("unexpected diagnostic payload");System.out.println("PASS fixed dump format and last apply preservation; no Android service/device execution");}
}
