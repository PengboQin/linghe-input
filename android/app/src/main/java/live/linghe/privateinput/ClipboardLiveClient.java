package live.linghe.privateinput;
import android.content.Context;import java.io.*;import java.net.*;import java.util.*;import java.math.BigInteger;import javax.net.ssl.HttpsURLConnection;import org.json.*;
/** One independent request at a time on the live worker, never the legacy actor. */
final class ClipboardLiveClient {
 interface Transport{JSONObject post(String endpoint,JSONObject request)throws Exception;}
 private final Context context;private final ClipboardLiveStore store;private final Transport transport;
 ClipboardLiveClient(Context c){this(c,new ClipboardLiveStore(c),ClipboardLiveClient::post);}
 ClipboardLiveClient(Context c,ClipboardLiveStore store,Transport transport){context=c.getApplicationContext();this.store=store;this.transport=transport;}
 private static long cursor(JSONObject j,String name)throws Exception{BigInteger n=SyncCrypto.u(j,name);SyncCrypto.require(n.bitLength()<=63);return n.longValueExact();}
 static JSONObject post(String endpoint,JSONObject value)throws Exception{
  URL url=new URL(SyncClient.endpoint(endpoint)+"/clipboard-live/v1/batch");HttpsURLConnection c=(HttpsURLConnection)url.openConnection();c.setInstanceFollowRedirects(false);c.setConnectTimeout(4000);c.setReadTimeout(5000);c.setRequestMethod("POST");c.setDoOutput(true);c.setRequestProperty("Content-Type","application/json");byte[] body=SyncCrypto.bytes(LosslessJson.canonical(value));c.setFixedLengthStreamingMode(body.length);
  try{try(OutputStream out=c.getOutputStream()){out.write(body);}int status=c.getResponseCode();if(status!=200)throw new SyncClient.HTTPFailure(status,"clipboard_live");ByteArrayOutputStream b=new ByteArrayOutputStream();try(InputStream in=c.getInputStream()){byte[] bytes=new byte[16384];int n;while((n=in.read(bytes))!=-1){SyncCrypto.require(b.size()+n<=1048576);b.write(bytes,0,n);}}return LosslessJson.object(SyncCrypto.utf8(b.toByteArray()),1048576);}finally{c.disconnect();}
 }
 boolean queue(String raw,String expectedScope)throws Exception{
  return store.change(s->{JSONObject c=s.optJSONObject("credential");if(!store.authorized(c)||!c.getString("scope").equals(expectedScope)||!s.optBoolean("available"))return false;ClipboardLiveStore.retireExpired(s,System.currentTimeMillis()/1000);JSONArray out=s.getJSONArray("outbox");SyncCrypto.require(out.length()<16);JSONObject wire=ClipboardLiveWire.seal(raw,c,System.currentTimeMillis()/1000);out.put(new JSONObject().put("wire",wire).put("text",raw));return true;});
 }
 static String receiptKey(JSONObject wire)throws Exception{return SyncCrypto.id(wire.getString("sender"))+"/"+SyncCrypto.id(wire.getString("event"));}
 static String digest(String kind,JSONObject wire)throws Exception{return SyncCrypto.b64(SyncCrypto.sha(SyncCrypto.concat(kind.equals("legacy")?SyncCrypto.eventHeader(wire):ClipboardLiveWire.eventHeader(wire),SyncCrypto.data(wire,"ciphertext"))));}
 void synchronize()throws Exception{
  store.change(s->{ClipboardLiveStore.retireExpired(s,System.currentTimeMillis()/1000);return null;});
  JSONObject before=store.snapshot(),credential=before.optJSONObject("credential");if(!store.authorized(credential))return;
  JSONArray out=before.getJSONArray("outbox");JSONObject pending=null;long after=cursor(before,"cursor"),now=System.currentTimeMillis()/1000;
  // An expired unsent value is retained; it does not block newer live copies.
  for(int n=0;n<out.length();n++)if(out.getJSONObject(n).getJSONObject("wire").getLong("expiresAt")>now){pending=out.getJSONObject(n);break;}
  final JSONObject published=pending;JSONObject body=new JSONObject().put("after",after).put("limit",16).put("publish",pending==null?JSONObject.NULL:pending.getJSONObject("wire"));
  AutoClipboardBridge bridge=AutoClipboardBridge.get(context);AutoClipboardState.Pass pass=bridge.beginPass(credential.getString("scope"),pending!=null);
  JSONObject response;
  try{response=transport.post(credential.getString("endpoint"),ClipboardLiveWire.request(credential,body,now));}
  catch(SyncClient.HTTPFailure failure){if(failure.status==404){store.change(s->{if(ClipboardLiveStore.sameCredential(credential,s.optJSONObject("credential")))s.put("available",false).put("unsupported",true);return null;});}throw failure;}
  SyncCrypto.require(response.getInt("version")==1);long head=cursor(response,"head"),next=cursor(response,"next");SyncCrypto.require(next>=after&&head>=next);JSONArray items=response.getJSONArray("items");SyncCrypto.require(items.length()<=16);
  if(published==null)SyncCrypto.require(response.isNull("accepted"));else SyncCrypto.require(!response.isNull("accepted")&&SyncCrypto.id(response.getString("accepted")).equals(SyncCrypto.id(published.getJSONObject("wire").getString("event"))));
  ArrayList<JSONObject> verified=new ArrayList<>();long previous=after;
  for(int n=0;n<items.length();n++){JSONObject item=items.getJSONObject(n);long at=cursor(item,"cursor");SyncCrypto.require(at>previous&&at<=next);previous=at;String kind=item.getString("kind");JSONObject wire=LosslessJson.object(SyncCrypto.utf8(SyncCrypto.data(item,"wire")),262144);String text=ClipboardLiveWire.open(kind,wire,credential,System.currentTimeMillis()/1000);verified.add(new JSONObject().put("kind",kind).put("wire",wire).put("text",text).put("digest",digest(kind,wire)));}
  ArrayList<AutoClipboardBridge.Incoming> fresh=new ArrayList<>();final boolean[] cold={false};
  synchronized(SyncClient.CONSENT_LOCK){
   SyncCrypto.require(store.authorized(credential));store.change(s->{SyncCrypto.require(store.authorized(s.optJSONObject("credential"))&&ClipboardLiveStore.sameCredential(credential,s.optJSONObject("credential"))&&cursor(s,"cursor")==after);cold[0]=!s.getBoolean("initialized");JSONObject receipts=s.getJSONObject("receipts");JSONArray inbox=s.getJSONArray("inbox");
    // Expired exact receipts can be retired; never evict a live replay record.
    ArrayList<String> expired=new ArrayList<>();Iterator<String> keys=receipts.keys();while(keys.hasNext()){String k=keys.next();if(receipts.getJSONObject(k).optLong("expiresAt")<=now)expired.add(k);}for(String k:expired)receipts.remove(k);
    for(JSONObject item:verified){JSONObject w=item.getJSONObject("wire");String key=receiptKey(w),kind=item.getString("kind"),hash=item.getString("digest");JSONObject seen=receipts.optJSONObject(key);boolean duplicate=seen!=null;if(seen==null){SyncCrypto.require(receipts.length()<1024);seen=new JSONObject().put("expiresAt",w.getLong("expiresAt")+600);receipts.put(key,seen);}if(seen.has(kind))SyncCrypto.require(hash.equals(seen.getString(kind)));seen.put(kind,hash);seen.put("expiresAt",Math.max(seen.getLong("expiresAt"),w.getLong("expiresAt")+600));
     if(!duplicate){inbox.put(new JSONObject().put("event",w.getString("event")).put("sender",w.getString("sender")).put("text",item.getString("text")).put("expiresAt",w.get("expiresAt")));if(!cold[0])fresh.add(new AutoClipboardBridge.Incoming(w.getString("sender"),w.getString("event"),item.getString("text"),w.getLong("expiresAt"),SyncCrypto.id(w.getString("sender")).equals(SyncCrypto.id(credential.getJSONObject("delegate").getJSONObject("certificate").getString("parent")))));}
    }
    while(inbox.length()>24)inbox.remove(0);
    if(published!=null){JSONArray current=s.getJSONArray("outbox");int index=-1;for(int n=0;n<current.length();n++)if(SyncCrypto.id(current.getJSONObject(n).getJSONObject("wire").getString("event")).equals(SyncCrypto.id(published.getJSONObject("wire").getString("event"))))index=n;SyncCrypto.require(index>=0);current.remove(index);JSONArray compatibility=s.getJSONArray("compatibility");while(compatibility.length()>=24)compatibility.remove(0);compatibility.put(new JSONObject().put("event",published.getJSONObject("wire").getString("event")).put("text",published.getString("text")).put("expiresAt",published.getJSONObject("wire").get("expiresAt")));}
    s.put("cursor",cold[0]?head:next).put("initialized",true).put("available",true).put("unsupported",false).put("lastSuccessAt",System.currentTimeMillis());return null;
   });
  }
  bridge.completedPass(pass,fresh,cold[0]||next==head,credential.getLong("consent"),credential.getLong("automatic"),credential.getString("privacy"));
 }
}
