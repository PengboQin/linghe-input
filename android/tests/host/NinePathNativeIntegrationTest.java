package live.linghe.privateinput;

import java.nio.file.Files;
import java.nio.file.Paths;

/** Actual product JNI and canonical core, loaded in a disposable host JVM. */
public final class NinePathNativeIntegrationTest {
 private static int checks;
 private static void check(boolean ok,String message){if(!ok)throw new AssertionError(message);checks++;}
 private static void type(long session,String code){for(char c:code.toCharArray())NativeCore.key(session,c);}
 private static long id(long session,String text){
  String[][] first=NativeCore.snapshot(session);for(int i=1;i<first.length;i++)if(first[i][1].equals(text))return Long.parseLong(first[i][0]);
  for(int offset=96;offset<1024;offset+=96){String[][] rows=NativeCore.more(session,offset);for(String[] row:rows)if(row[1].equals(text))return Long.parseLong(row[0]);if(rows.length<96)break;}
  throw new AssertionError("native target absent: "+text);
 }
 private static void visible(long session,String raw){
  String[][] proof=NativeCore.query(session,"nishuosha",false,96);boolean found=false;for(String[] row:proof)if(row[1].equals("你说啥")&&row[2].equals("ni shuo sha"))found=true;
  check(found,"whole corrected candidate was a real public-dictionary result");
  check(NativeCore.rememberVisibleNinePath(session,raw,"","你说啥","ni shuo sha","647486742"),"visible corrected path bound through actual JNI");
 }
 public static void main(String[] args)throws Exception{
  check(args.length==2&&!Files.exists(Paths.get(args[1])),"new owned fixture user only");
  long session=NativeCore.create(args[0],args[1]);check(session!=0,"JNI engine create");
  try{
   NativeCore.mode(session,true,true);String raw="64746742";type(session,raw);visible(session,raw);
   NativeCore.choose(session,id(session,"你"));String[][] partial=NativeCore.snapshot(session);
   check(partial[0][1].isEmpty()&&partial[0][2].equals(raw)&&partial[0][4].equals("你"),"partial selection preserves raw and never commits tail");
   check(NativeCore.preferredNineText(session).equals("说啥")&&NativeCore.preferredNineReading(session).equals("shuo sha"),"immediate tail arrives through JNI without quality preparation");
   check(partial[0][3].contains("shuo sha")&&!partial[0][3].contains("pin sha"),"inline marked snapshot uses retained reading instead of temporary native guess");
   String[][] shown=NinePathOrder.carry(partial,NativeCore.preferredNineText(session),NativeCore.preferredNineReading(session),true,0);
   String[] readings=new String[shown.length-1];for(int i=1;i<shown.length;i++)readings[i-1]=shown[i][2];shown=NinePathOrder.apply(shown,NativeCore.ninePathPriorities(session,readings),0);
   check(shown[1][1].equals("说啥"),"actual native core tiers publish correct tail first");
   boolean prefix=false;for(String[] row:shown)if(row[0].equals("path:prefix")&&row[1].equals("说"))prefix=true;check(prefix,"first-character adjustment is immediately available");
   check(NativeCore.selectPreferredNinePrefix(session,raw,"你","说","shuo"),"explicit carried prefix succeeds through JNI");
   String[][] next=NativeCore.snapshot(session);check(next[0][1].isEmpty()&&next[0][4].equals("你说")&&NativeCore.preferredNineText(session).equals("啥"),"second partial choice stays pending with known tail");
   NativeCore.delete(session);check(NativeCore.draft(session)[1].equals("你"),"delete reopens last partial word");
   NativeCore.delete(session);check(NativeCore.draft(session)[1].isEmpty()&&NativeCore.draft(session)[0].equals(raw),"second delete restores full original typo code");
   NativeCore.choose(session,id(session,"你"));NativeCore.snapshot(session);
   check(NativeCore.commitPreferredNine(session,raw,"你","说啥","shuo sha").equals("你说啥"),"explicit known full tail commits selected prefix exactly once");
   check(NativeCore.commitPreferredNine(session,raw,"你","说啥","shuo sha").isEmpty()&&NativeCore.snapshot(session)[0][1].isEmpty(),"no duplicate native or direct-result commit");
   type(session,raw);visible(session,raw);NativeCore.choose(session,id(session,"你"));NativeCore.snapshot(session);NativeCore.key(session,'7');
   check(NativeCore.preferredNineText(session).isEmpty()&&NativeCore.commitPreferredNine(session,raw,"你","说啥","shuo sha").isEmpty(),"fresh key fences stale carried text");
   NativeCore.mode(session,false,true);type(session,"nishuosha");check(!NativeCore.rememberVisibleNinePath(session,"nishuosha","","你说啥","ni shuo sha",null),"26-key sequence not taken over");
   check(NativeCore.preferredNineText(session).isEmpty(),"mode change clears mobile soft path");
  }finally{NativeCore.destroy(session);}
  System.out.println("PASS "+checks+" actual JNI/core checks; synthetic host JVM only, no phone/network/real personal data");
 }
}
