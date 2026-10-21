package live.linghe.privateinput;
import android.app.Instrumentation;
import android.content.*;
import android.os.Bundle;
import java.io.*;
import java.lang.reflect.Field;
import java.math.BigInteger;
import java.util.*;
import org.json.*;

/** Test UID + fresh namespaced files/preferences/Keystore aliases only. No HTTP,
 * app profile, real group, clipboard, input source, or user text is accessed. */
public final class SyncBacklogRecoveryCheck extends Instrumentation {
  int checks;volatile String stage="create";Context base;String nonce;File root;ArrayList<Fixture> fixtures=new ArrayList<>();
  interface Action {void run()throws Exception;}
  void status(String name){stage=name;Bundle b=new Bundle();b.putString("stage",name);b.putInt("checks",checks);sendStatus(1,b);}
  void require(boolean ok,String label){checks++;if(!ok)throw new AssertionError(label);}
  void rejects(Action action,String label)throws Exception {boolean rejected=false;try{action.run();}catch(Exception expected){rejected=true;}require(rejected,label);}
  static JSONObject copy(JSONObject value)throws Exception{return LosslessJson.object(LosslessJson.canonical(value),6*1024*1024);}
  final class Fixture implements SyncClient.RequestTransport {
    final Context context;final SyncStore store;final JSONObject member,peer,membership;final byte[] key=SyncCrypto.random(32);
    final ArrayList<JSONObject> incoming=new ArrayList<>();final ArrayList<String> calls=new ArrayList<>();
    SyncClient client;int free,cost=1,ackCount,pushCount,recentCalls;boolean loseAck,misroute,emptyFallback;JSONObject rotatedMembership,rotatedKeyPackage;Action pullAction,ackAction;
    final ArrayList<Integer> masks=new ArrayList<>(),pushedDomains=new ArrayList<>();final ArrayList<BigInteger> pushedSequences=new ArrayList<>();
    Fixture(String name,int count,boolean outbound)throws Exception {
      File directory=new File(root,name),files=new File(directory,"files"),cache=new File(directory,"cache");files.mkdirs();cache.mkdirs();
      context=new ContextWrapper(base){public Context getApplicationContext(){return this;}public File getFilesDir(){return files;}public File getCacheDir(){return cache;}public SharedPreferences getSharedPreferences(String key,int mode){return base.getSharedPreferences("backlog-"+nonce+"-"+name+"-"+key,mode);}};
      store=new SyncStore(context,"live.linghe.privateinput.tests.backlog."+nonce+"."+name);fixtures.add(this);
      member=SyncCrypto.identity();peer=SyncCrypto.identity();membership=SyncCrypto.newMembership(member);
      membership.put("members",new JSONArray().put(SyncCrypto.member(member)).put(SyncCrypto.member(peer)));
      membership.put("signature",SyncCrypto.b64(SyncCrypto.sign(SyncCrypto.membership(membership),SyncCrypto.privateKey("Ed25519",member.getString("owner")))));
      JSONObject state=store.load();state.put("identity",member).put("membership",membership).put("anchor",SyncCrypto.anchor(membership)).put("groupKey",SyncCrypto.b64(key)).put("endpoint","https://synthetic.invalid").put("profileRegistered",true).put("privacyEpoch","initial");
      context.getSharedPreferences("sync-consent",0).edit().putLong("generation",7).putBoolean("learning",false).putBoolean("clipboard",true).commit();
      if(outbound){JSONObject wire=wire(member,1,"合成待上传");state.getJSONArray("outbox").put(new JSONObject().put("wire",wire).put("generation",7));state.put("sequence",1);}
      store.save(state);client=new SyncClient(context,store,this);
      for(int i=1;i<=count;i++)incoming.add(wire(peer,i,"合成待接收"+i));
    }
    JSONObject wire(JSONObject identity,int sequence,String text)throws Exception {return wire(identity,sequence,text,2);}
    JSONObject wire(JSONObject identity,int sequence,String text,int domain)throws Exception {
      JSONObject sender=new JSONObject().put("identity",identity).put("membership",membership).put("groupKey",SyncCrypto.b64(key)).put("sequence",sequence);
      return SyncCrypto.seal(SyncCrypto.bytes(text),domain,sender,System.currentTimeMillis()/1000);
    }
    JSONObject learningWire(int sequence,long count)throws Exception{LearningModel model=new LearningModel();model.setDeviceCount("ni hao","你好",peer.getString("device"),count);return wire(peer,sequence,model.export(),1);}
    void automaticLearning()throws Exception{context.getSharedPreferences("sync-consent",0).edit().putBoolean("learning",true).putBoolean(AutoClipboardBridge.ENABLED,true).commit();free=1000;Field bridge=AutoClipboardBridge.class.getDeclaredField("instance");bridge.setAccessible(true);bridge.set(null,null);reload();}
    boolean armed()throws Exception{runOnMainSync(()->{});Field instance=AutoClipboardBridge.class.getDeclaredField("instance");instance.setAccessible(true);Object bridge=instance.get(null);if(bridge==null)return false;Field field=AutoClipboardBridge.class.getDeclaredField("state");field.setAccessible(true);Field armed=AutoClipboardState.class.getDeclaredField("armed");armed.setAccessible(true);return armed.getBoolean(field.get(bridge));}
    String ledgerKey(JSONObject wire)throws Exception{return SyncCrypto.id(wire.getString("group"))+"/"+SyncCrypto.u(wire,"epoch")+"/"+SyncCrypto.id(wire.getString("sender"));}
    void reload()throws Exception{client=new SyncClient(context,store,this);}
    JSONObject state()throws Exception{return store.load();}
    JSONObject memory()throws Exception{Field f=SyncClient.class.getDeclaredField("state");f.setAccessible(true);return (JSONObject)f.get(client);}
    public JSONObject request(String endpoint,String method,String path,JSONObject body)throws Exception {
      if(path.equals("/clipboard-live/v1/revoke"))return new JSONObject().put("version",1).put("revoked",true).put("generation",body.get("generation"));
      if(path.endsWith("/recency")){recentCalls++;throw new IOException("synthetic optional lane unavailable");}
      if(path.endsWith("/events")){calls.add("push");pushCount++;pushedDomains.add(body.getInt("domain"));pushedSequences.add(SyncCrypto.u(body,"sequence"));if(free<cost)throw new SyncClient.HTTPFailure(429,"quota");free-=cost;return new JSONObject().put("accepted",true).put("event",body.get("event"));}
      if(!path.endsWith("/rpc"))throw new AssertionError("Unexpected endpoint");
      int op=body.getInt("operation");
      if(op==1)return new JSONObject().put("membership",rotatedMembership==null?membership:rotatedMembership);
      if(op==4&&rotatedKeyPackage!=null)return new JSONObject().put("package",rotatedKeyPackage);
      if(op==12)return new JSONObject().put("departed",false).put("devices",new JSONArray());
      if(op==9)return new JSONObject().put("claims",new JSONArray());
      if(op==2){calls.add("pull");if(pullAction!=null)pullAction.run();JSONObject request=LosslessJson.object(SyncCrypto.utf8(SyncCrypto.data(body,"body")),65536);int mask=request.getInt("domains");masks.add(mask);JSONArray items=new JSONArray();if(!(emptyFallback&&mask==3))for(JSONObject wire:incoming)if((misroute||(wire.getInt("domain")&mask)!=0)&&items.length()<2)items.put(wire);return new JSONObject().put("events",items);}
      if(op==3){
        calls.add("ack");ackCount++;
        JSONObject request=LosslessJson.object(SyncCrypto.utf8(SyncCrypto.data(body,"body")),65536);JSONArray events=request.getJSONArray("events");
        require(events.length()<=2,"bounded ACK request");
        for(int n=0;n<events.length();n++)require(state().getJSONObject("receiveReceipts").has(SyncCrypto.id(events.getString(n))),"ACK follows durable exact receipt");
        boolean clipAck=false;for(JSONObject pending:incoming)for(int n=0;n<events.length();n++)clipAck|=pending.getString("event").equals(events.getString(n))&&pending.getInt("domain")==2;if(clipAck)require(state().getJSONArray("inbox").length()>0,"ACK follows durable inbox");
        if(ackAction!=null)ackAction.run();
        if(loseAck){loseAck=false;throw new SyncClient.HTTPFailure(503,"synthetic_lost_ack");}
        for(int n=0;n<events.length();n++)for(Iterator<JSONObject> i=incoming.iterator();i.hasNext();)if(i.next().getString("event").equals(events.getString(n))){i.remove();free++;}
        return new JSONObject().put("accepted",true);
      }
      throw new AssertionError("Unexpected RPC "+op);
    }
  }
  @Override public void onCreate(Bundle arguments){super.onCreate(arguments);start();}
  @Override public void onStart(){Bundle result=new Bundle();try{
    Thread watchdog=new Thread(()->{try{Thread.sleep(45000);Bundle b=new Bundle();StringBuilder trace=new StringBuilder("stage="+stage+"\n");for(Map.Entry<Thread,StackTraceElement[]> row:Thread.getAllStackTraces().entrySet())if(row.getKey().getName().equals("main")||row.getKey().getName().contains("Instr")){trace.append(row.getKey().getName()).append(": ").append(row.getKey().getState()).append('\n');for(StackTraceElement frame:row.getValue())trace.append(frame.toString()).append('\n');}b.putString("syntheticTestThreadTrace",trace.toString());sendStatus(2,b);}catch(Exception ignored){}});watchdog.setDaemon(true);watchdog.start();
    base=getTargetContext();require(base.getPackageName().equals("live.linghe.privateinput.tests"),"isolated test UID only");nonce=UUID.randomUUID().toString();root=new File(base.getCacheDir(),"backlog-"+nonce);root.mkdirs();
    status("active-short-cadence");Fixture active=new Fixture("active-cadence",0,false);active.automaticLearning();active.client.synchronizeAutomatic(false);active.reload();active.client.synchronizeAutomatic(false);
    require(active.masks.equals(Arrays.asList(2,2)),"successive active clipboard turns do not enter persisted learning phase");require(active.recentCalls==0,"active clipboard polls skip recency/export");active.reload();active.client.synchronizeAutomatic(true);require(active.masks.get(active.masks.size()-1)==1&&active.recentCalls==1,"scheduled maintenance still progresses learning/recency");
    Fixture quota=new Fixture("quota",4,true);quota.cost=3;
    rejects(()->quota.client.synchronize(),"first bounded drain still quota");
    require(quota.state().getJSONArray("inbox").length()==2&&quota.state().getJSONArray("outbox").length()==1,"429 retains received state and outgoing event");
    require(quota.incoming.size()==2&&quota.calls.equals(Arrays.asList("pull","ack","push")),"at most two receives precede first push");
    quota.reload();quota.client.synchronize();require(quota.state().getJSONArray("inbox").length()==4&&quota.state().getJSONArray("outbox").length()==0,"restart and next pass recover queue");
    Fixture bad=new Fixture("bad-signature",1,true);bad.incoming.get(0).put("signature",SyncCrypto.b64(new byte[64]));rejects(()->bad.client.synchronize(),"invalid signature rejected");require(bad.ackCount==0&&bad.pushCount==0,"invalid signature neither ACK nor push");
    Fixture malformed=new Fixture("ledger-error",1,true);JSONObject wire=malformed.incoming.get(0),saved=malformed.state();String ledgerKey=SyncCrypto.id(wire.getString("group"))+"/"+SyncCrypto.u(wire,"epoch")+"/"+SyncCrypto.id(wire.getString("sender"));saved.getJSONObject("ledger").put(ledgerKey,new JSONObject().put("highest",-1).put("bitmap","1"));malformed.store.save(saved);malformed.reload();rejects(()->malformed.client.synchronize(),"generic ledger IOException is not duplicate");require(malformed.ackCount==0,"generic IOException cannot ACK");
    Fixture persistence=new Fixture("persist-failure",1,true);File blocked=new File(persistence.context.getFilesDir(),"Sync/state-v1.enc.new");persistence.pullAction=()->{require(blocked.mkdir(),"inject AtomicFile write failure");};rejects(()->persistence.client.synchronize(),"failed durable state save rejected");require(persistence.ackCount==0&&persistence.pushCount==0,"failed save neither ACK nor push");require(!blocked.exists()||blocked.delete(),"clear owned failure fixture");persistence.pullAction=null;persistence.reload();persistence.client.synchronize();require(persistence.state().getJSONArray("inbox").length()==1,"durable retry applies once");
    Fixture consent=new Fixture("consent",1,true);consent.pullAction=()->{consent.client.consent(false,false);consent.client.consent(false,true);};rejects(()->consent.client.synchronize(),"retired generation after reenable rejected");require(consent.ackCount==0&&consent.pushCount==0&&consent.state().getJSONArray("inbox").length()==0,"retired pass no receive ACK push");
    Fixture lost=new Fixture("lost-ack",1,false);lost.loseAck=true;rejects(()->lost.client.synchronize(),"lost ACK retains packet at relay");require(lost.state().getJSONArray("inbox").length()==1,"lost ACK already persisted");lost.reload();lost.client.synchronize();require(lost.state().getJSONArray("inbox").length()==1&&lost.incoming.isEmpty(),"duplicate exact receipt ACK without duplicate apply");
    Fixture legacy=new Fixture("legacy-ledger",1,false);JSONObject old=legacy.state(),oldWire=legacy.incoming.get(0);String oldKey=SyncCrypto.id(oldWire.getString("group"))+"/"+SyncCrypto.u(oldWire,"epoch")+"/"+SyncCrypto.id(oldWire.getString("sender"));old.getJSONObject("ledger").put(oldKey,new JSONObject().put("highest",1).put("bitmap","1"));old.put("acks",new JSONArray().put(oldWire.get("event")));legacy.store.save(old);legacy.reload();legacy.client.synchronize();require(legacy.state().getJSONArray("inbox").length()==1&&legacy.incoming.isEmpty()&&!legacy.state().has("acks"),"legacy replay reapplied and persisted before ACK");
    // Filtered clipboard preview must never evict old learning from the same
    // sender's shared 64-bit replay window. The fake relay has the real mask/
    // FIFO/ACK semantics; the client uses real encrypted store and crypto.
    status("original-seven-pass");Fixture split=new Fixture("split-gap",0,false);split.automaticLearning();
    for(int seq=1;seq<=80;seq++)split.incoming.add(split.learningWire(seq,seq));split.incoming.add(split.wire(split.peer,100,"合成旧剪贴板"));
    status("split-first-sync");split.client.synchronize();status("split-first-complete");require(split.masks.equals(Arrays.asList(2,3)),"unknown window performs one ordered fallback");require(split.state().getJSONObject("receiveReceipts").length()==2&&split.incoming.size()==79,"only fallback two applied and ACKed, preview retained");status("split-before-armed");require(!split.armed(),"fallback cannot fake an empty clipboard observation");require(split.recentCalls==0,"clipboard turn performs no recency lane");
    split.reload();split.client.synchronize();require(split.masks.get(split.masks.size()-1)==1,"persisted next turn is learning across new client");require(split.recentCalls==1,"learning turn keeps optional recency protocol");
    for(int round=0;round<90&&!split.incoming.isEmpty();round++){if(round%10==0)status("split-round-"+round);split.reload();split.client.synchronize();require(split.masks.size()<=2*(round+3),"one bounded safety fallback per turn");}
    require(split.incoming.isEmpty(),"all eighty old learning messages and later clipboard remain reachable");LearningModel retained=new LearningModel();retained.merge(new LearningSnapshotFile(new File(split.context.getFilesDir(),"Shared")).read());require(retained.entries().get(0).frequency()==80,"cross-domain gap above64 loses no old frequency");require(split.state().getJSONObject("receiveReceipts").length()==81,"every old event has a durable exact receipt");
    Fixture hole=new Fixture("hole",0,false);hole.automaticLearning();JSONObject l37=hole.learningWire(37,37);hole.incoming.add(l37);hole.incoming.add(hole.wire(hole.peer,101,"合成新板"));JSONObject hs=hole.state();hs.getJSONObject("ledger").put(hole.ledgerKey(l37),new JSONObject().put("highest",100).put("bitmap","1"));hole.store.save(hs);hole.reload();hole.client.synchronize();require(hole.masks.equals(Arrays.asList(2,3)),"an unseen positive oldest hole forces ordered fallback");require(hole.state().getJSONObject("receiveReceipts").has(l37.getString("event")),"hole's old learning persists before high clipboard advances");
    Fixture fifo=new Fixture("outgoing-fifo",0,false);fifo.automaticLearning();JSONObject fs=fifo.state();LearningModel fm=new LearningModel();fm.setDeviceCount("ni hao","你好",fifo.member.getString("device"),1);JSONObject oldLearning=fifo.wire(fifo.member,1,fm.export(),1),newClip=fifo.wire(fifo.member,100,"合成新复制");fs.put("sequence",100).getJSONArray("outbox").put(new JSONObject().put("wire",oldLearning).put("generation",7)).put(new JSONObject().put("wire",newClip).put("generation",7));fifo.store.save(fs);fifo.reload();fifo.client.synchronize();require(fifo.pushedDomains.equals(Arrays.asList(1,2))&&fifo.pushedSequences.equals(Arrays.asList(BigInteger.ONE,BigInteger.valueOf(100))),"clipboard turn retains global outgoing FIFO across gap above64");require(fifo.recentCalls==0,"old FIFO flush does not generate new learning/recency in clip turn");
    Fixture fallbackEmpty=new Fixture("fallback-empty",1,false);fallbackEmpty.automaticLearning();fallbackEmpty.emptyFallback=true;fallbackEmpty.client.synchronize();require(fallbackEmpty.masks.equals(Arrays.asList(2,3))&&fallbackEmpty.ackCount==0&&!fallbackEmpty.armed(),"empty ordered fallback is not clipboard cold completion");
    Fixture wrong=new Fixture("wrong-domain",0,false);wrong.automaticLearning();wrong.misroute=true;wrong.incoming.add(wrong.learningWire(1,1));rejects(()->wrong.client.synchronize(),"wrong domain preview rejected");require(wrong.ackCount==0,"wrong domain never ACKed");
    Fixture journal=new Fixture("deferred-journal",0,false);journal.automaticLearning();JSONObject jw=journal.learningWire(1,1),js=journal.state();js.put("pendingIncoming",new JSONObject().put("wire",jw).put("payload",SyncCrypto.b64(SyncCrypto.open(jw,journal.membership,journal.key,System.currentTimeMillis()/1000))).put("ledger",new JSONObject()).put("generation",7));js.getJSONObject("ledger").put(journal.ledgerKey(jw),new JSONObject().put("highest",2).put("bitmap","1"));journal.store.save(js);journal.incoming.add(journal.wire(journal.peer,3,"合成跨域"));journal.reload();journal.client.synchronize();require(journal.state().has("pendingIncoming"),"clipboard turn does not overwrite deferred learning journal");journal.reload();journal.client.synchronize();JSONObject window=journal.state().getJSONObject("ledger").getJSONObject(journal.ledgerKey(jw));require(SyncCrypto.u(window,"highest").intValue()==3&&(Long.parseUnsignedLong(window.getString("bitmap"),16)&7)==7,"deferred journal rebases without rolling back newer domain ledger");
    Fixture quotaTurn=new Fixture("quota-turn",0,true);quotaTurn.automaticLearning();quotaTurn.free=0;rejects(()->quotaTurn.client.synchronize(),"quota upload retained");require(quotaTurn.state().getJSONArray("outbox").length()==1&&quotaTurn.state().getInt("automaticSyncNextDomain")==1,"quota does not starve the other turn or lose original event");
    Fixture revokePending=new Fixture("revoke-pending",0,false);revokePending.automaticLearning();JSONObject rs=revokePending.state();for(String key:new String[]{"pendingIncoming","pendingLearningIncoming","pendingClipboardIncoming"}){JSONObject retiredWire=key.equals("pendingClipboardIncoming")?revokePending.wire(revokePending.peer,12,"合成撤销暂存"):revokePending.learningWire(key.equals("pendingIncoming")?10:11,1);rs.put(key,new JSONObject().put("wire",retiredWire).put("payload",SyncCrypto.b64(SyncCrypto.open(retiredWire,revokePending.membership,revokePending.key,System.currentTimeMillis()/1000))).put("ledger",new JSONObject()).put("generation",7));}revokePending.store.save(rs);revokePending.reload();revokePending.client.consent(false,true);revokePending.reload();revokePending.client.synchronize();require(!revokePending.state().has("pendingIncoming")&&!revokePending.state().has("pendingLearningIncoming")&&!revokePending.state().has("pendingClipboardIncoming"),"consent generation retires every old/new pending key");
    Fixture rotatePending=new Fixture("rotate-pending",0,false);rotatePending.automaticLearning();JSONObject rot=rotatePending.state();for(String key:new String[]{"pendingIncoming","pendingLearningIncoming","pendingClipboardIncoming"}){JSONObject rotatedWire=key.equals("pendingClipboardIncoming")?rotatePending.wire(rotatePending.peer,22,"合成旧代际暂存"):rotatePending.learningWire(key.equals("pendingIncoming")?20:21,1);rot.put(key,new JSONObject().put("wire",rotatedWire).put("payload",SyncCrypto.b64(SyncCrypto.open(rotatedWire,rotatePending.membership,rotatePending.key,System.currentTimeMillis()/1000))).put("ledger",new JSONObject()).put("generation",7));}rotatePending.store.save(rot);rotatePending.reload();rotatePending.rotatedMembership=SyncCrypto.successor(rotatePending.membership,rotatePending.membership.getJSONArray("members"),rotatePending.member);rotatePending.rotatedKeyPackage=SyncCrypto.wrap(rotatePending.rotatedMembership,rotatePending.member.getString("device"),SyncCrypto.random(32),new byte[32],rotatePending.member,System.currentTimeMillis()/1000,System.currentTimeMillis()/1000+600);rotatePending.client.synchronize();JSONObject rotated=rotatePending.state();require(rotated.getJSONObject("heldIncoming").length()==3&&!rotated.has("pendingIncoming")&&!rotated.has("pendingLearningIncoming")&&!rotated.has("pendingClipboardIncoming"),"authenticated epoch rotation isolates all pending payloads without applying under new key");rotatePending.store.resetForDeparture();JSONObject reset=rotatePending.store.load();require(!reset.has("heldIncoming")&&!reset.has("pendingIncoming")&&!reset.has("pendingLearningIncoming")&&!reset.has("pendingClipboardIncoming"),"actual encrypted-store departure reset clears every pending and held key");
    result.putString("result","Passed");result.putInt("checks",checks);result.putBoolean("network",false);result.putBoolean("realGroupAccess",false);finish(-1,result);
  }catch(Throwable failure){result.putString("result","Failed");result.putString("error",failure.toString());result.putInt("checks",checks);finish(0,result);}
  finally{for(Fixture fixture:fixtures)try{fixture.store.resetForDeparture();}catch(Exception ignored){}if(root!=null)try{remove(root);}catch(Exception ignored){}}}
  void remove(File file)throws IOException{File[] children=file.listFiles();if(children!=null)for(File child:children)remove(child);if(file.exists()&&!file.delete())throw new IOException("owned fixture cleanup");}
}
