package live.linghe.privateinput;

import java.io.File;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardOpenOption;
import org.json.JSONObject;

/** Synthetic Android JSON runtime check. Never opens a product directory or native DB. */
public final class CliRimeZeroRoundtrip {
 private static int assertions;
 interface Work {void run()throws Exception;}
 private static void check(boolean value){++assertions;if(!value)throw new AssertionError();}
 private static void reject(Work work)throws Exception{boolean bad=false;try{work.run();}catch(Exception expected){bad=true;}check(bad);}
 private static String id(String word){return "ce shi\u001f"+word;}
 private static String row(String word,int count){return word+"\tce shi\t"+count+"\n";}
 private static String exported(int positive,int zero){StringBuilder out=new StringBuilder();for(int i=0;i<positive;i++)out.append(row("合成正词"+i,1));for(int i=0;i<zero;i++)out.append(row("合成零词"+i,0));return out.toString();}
 private static JSONObject object(RimeCheckpoint state)throws Exception{return LosslessJson.object(state.encode(),RimeCheckpoint.MAX_STATE_BYTES);}
 private static RimeCheckpoint roundtrip(RimeCheckpoint state)throws Exception{String before=state.encode();RimeCheckpoint after=RimeCheckpoint.decode(before);check(after.encode().equals(before));return after;}
 private static File fixture(String[] args)throws Exception {
  check(args.length==1);File root=new File(args[0]);check(root.isAbsolute()&&root.getAbsoluteFile().equals(root.getCanonicalFile()));
  File parent=root.getParentFile();check(root.getName().equals("data")&&parent!=null&&parent.getName().matches("linghe-rime-zero-[0-9a-f]{16,64}"));
  check(parent.getParentFile()!=null&&parent.getParentFile().getAbsolutePath().equals("/data/local/tmp")&&parent.isDirectory());
  check(!root.exists()&&root.mkdir());return root;
 }
 private static void largeJsonRoundtrip(File root)throws Exception {
  String export=exported(4650,615);check(RimeCheckpoint.parseExport(export).size()==5265);RimeCheckpoint state=new RimeCheckpoint();state.observeExport(export,"synthetic-shell");
  check(state.model.entries().size()==4650);check(object(state).getJSONObject("observedCounts").length()==4650);
  state.establishBaselineAfterImport(export);check(object(state).getJSONObject("observedCounts").length()==4650);check(object(state).getJSONObject("appliedGenerations").length()==4650);
  state.setPinned("ce shi","合成正词0",true,"synthetic-shell");state.model.remove(id("合成正词1"));state.resetFrequency("ce shi","合成正词2");
  String encoded=state.encode();File saved=new File(root,"checkpoint-roundtrip.json");check(saved.getCanonicalFile().getParentFile().equals(root));Files.write(saved.toPath(),encoded.getBytes(StandardCharsets.UTF_8),StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE);
  String read=new String(Files.readAllBytes(saved.toPath()),StandardCharsets.UTF_8);check(encoded.equals(read));RimeCheckpoint recovered=RimeCheckpoint.decode(read);check(recovered.encode().equals(encoded));
  for(int i=0;i<2;i++){recovered.observeExport(export,"synthetic-shell");check(recovered.encode().equals(encoded));}
  check(recovered.model.get(id("合成正词0")).pinned);check(recovered.model.get(id("合成正词1")).deleted);check(recovered.model.get(id("合成正词2")).generation.equals(BigInteger.ONE));check(recovered.pendingResets().size()==1);
  JSONObject counts=object(recovered).getJSONObject("observedCounts");check(counts.length()==4650);check(!counts.has(id("合成零词0"))&&!counts.has(id("合成零词614")));check(counts.getLong(id("合成正词2"))==1);
 }
 private static void zeroAndPositiveBaseline()throws Exception {
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("回零",7)+row("保留",9),"synthetic-shell");state.observeExport(row("回零",0)+row("新零",0),"synthetic-shell");state=roundtrip(state);
  JSONObject counts=object(state).getJSONObject("observedCounts");check(!counts.has(id("回零"))&&!counts.has(id("新零")));check(counts.getLong(id("保留"))==9);check(state.model.get(id("回零")).frequency()==7);
  state.observeExport(row("回零",1),"synthetic-shell");check(state.model.get(id("回零")).frequency()==8);String once=state.encode();state=RimeCheckpoint.decode(once);state.observeExport(row("回零",1),"synthetic-shell");state.observeExport(row("回零",1),"synthetic-shell");check(state.encode().equals(once));check(object(state).getJSONObject("observedCounts").getLong(id("保留"))==9);
  JSONObject legacy=object(state);legacy.getJSONObject("observedCounts").put(id("旧零基线"),0);state=RimeCheckpoint.decode(LosslessJson.canonical(legacy));state.observeExport("","synthetic-shell");counts=object(state).getJSONObject("observedCounts");check(!counts.has(id("旧零基线")));check(counts.getLong(id("回零"))==1&&counts.getLong(id("保留"))==9);roundtrip(state);
 }
 private static void atomicRejection()throws Exception {
  RimeCheckpoint state=new RimeCheckpoint();state.observeExport(row("原词",4),"synthetic-shell");state.establishBaselineAfterImport(row("原词",4));state.setPinned("ce shi","原词",true,"synthetic-shell");
  String before=state.encode();String[] invalid={row("重复零",0)+row("重复零",0),"坏码\tce1\t0\n","坏\u0000字\tce shi\t0\n",row("正零重复",1)+row("正零重复",0)};
  for(String bad:invalid){final String text=row("原词",5)+bad;reject(()->state.observeExport(text,"synthetic-shell"));check(state.encode().equals(before));reject(()->state.establishBaselineAfterImport(text));check(state.encode().equals(before));}
  String overflow=exported(5001,0);reject(()->state.observeExport(overflow,"synthetic-shell"));check(state.encode().equals(before));check(roundtrip(state).model.get(id("原词")).pinned);
 }
 public static void main(String[] args){
  try{File root=fixture(args);check(new JSONObject().put("counter",4650).getLong("counter")==4650);largeJsonRoundtrip(root);zeroAndPositiveBaseline();atomicRejection();System.out.println("{\"passed\":true,\"assertions\":"+assertions+",\"androidJsonRuntime\":true,\"allDataSynthetic\":true,\"productDirectoryTouched\":false,\"nativeDatabaseTouched\":false}");}
  catch(Throwable error){System.out.println("{\"passed\":false,\"assertions\":"+assertions+",\"allDataSynthetic\":true,\"productDirectoryTouched\":false,\"nativeDatabaseTouched\":false}");System.exit(1);}
 }
}
