package live.linghe.privateinput;
import java.util.*;
public class ActivitySourceContextTest {
 public static void main(String[] args){int n=0;Map<String,String> a=ActivitySourceContext.fields("android","com.example.Host","合成宿主","0.1.29","30","android_input_type_2","ime_action_6","nine","default_ime");if(!a.get("app_identity_status").equals("available"))throw new AssertionError();n++;
 Map<String,String> b=ActivitySourceContext.fields("ios",null,"Do not guess",null,null,"number","send","nine","keyboard_extension");if(b.containsKey("source_app_name")||!b.get("app_identity_status").equals("unavailable"))throw new AssertionError();n++;
 if(ActivitySourceContext.fields("windows","C:\\Example\\User\\Editor.exe","Editor",null,null,null,null,null,null).containsKey("source_app_id"))throw new AssertionError();n++;
 if(ActivitySourceContext.fields("android","com.example","bad\nname",null,null,null,null,null,null).containsKey("source_app_name"))throw new AssertionError();n++;
 if(ActivitySourceContext.fields("android","com.example",String.join("",Collections.nCopies(90,"汉")),null,null,null,null,null,null).containsKey("source_app_name"))throw new AssertionError();n++;
 if(!ActivitySourceContext.fields("android","com.example",null,null,null,null,null,null,null).get("app_identity_status").equals("identifier_only"))throw new AssertionError();n++;
 try{a.put("window_title","forbidden");throw new AssertionError();}catch(UnsupportedOperationException ok){n++;}
 if(a.containsKey("process_path")||a.containsKey("window_title"))throw new AssertionError();n++;
 System.out.println("PASS source context Java assertions "+n);
 }
}
