package live.linghe.privateinput;
import android.content.*;
import java.io.*;
import java.net.*;
import java.util.*;
import java.math.BigInteger;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;
/** Explicit sync in the containing app; input service never waits for network. */
final class SyncClient {
  static final Object CONSENT_LOCK=new Object();
  private final Context context;
  private final SyncStore store;
  private final SharedPreferences prefs;
  private JSONObject state;
  private String pairingWait="";
  interface RequestTransport {JSONObject request(String endpoint,String method,String path,JSONObject body)throws Exception;}
  private final RequestTransport transport;
  String pairingWaitReason(){return pairingWait;}
  SyncClient(Context context)throws Exception{this(context,null);}
  SyncClient(Context context,SyncStore storage)throws Exception{this(context,storage,null);}
  // Package-private deterministic transport seam; normal app constructors always
  // use the TLS implementation. No UI, preference or network option enables it.
  SyncClient(Context context,SyncStore storage,RequestTransport transport)throws Exception{
    this.context=context.getApplicationContext();
    this.transport=transport;
    store=storage==null?new SyncStore(this.context):storage;
    prefs=this.context.getSharedPreferences("sync-consent",0);
    PersonalReset.deadline(this.context);
    state=store.load();
    if(state.optBoolean("wipePending"))resetForDeparture(this.context.getSharedPreferences("privacy-reset",0).getString("reason","removed"));
    String epoch=PersonalReset.generation(this.context);
    if(state.has("membership")&&state.has("privacyEpoch")&&!epoch.equals("initial")&&!epoch.equals(state.optString("privacyEpoch")))resetForDeparture(this.context.getSharedPreferences("privacy-reset",0).getString("reason","inactive"));

  }
  private long now(){
    return System.currentTimeMillis()/1000;
  }
  private void save()throws Exception{
    store.save(state);
  }
  private JSONObject identity()throws Exception{
    if(!state.has("identity")){
      state.put("identity",SyncCrypto.identity());
      save();
    }
    return state.getJSONObject("identity");
  }
  static String endpoint(String text)throws Exception{
    URI uri=new URI(text.trim());
    SyncCrypto.require("https".equals(uri.getScheme())&&uri.getHost()!=null&&uri.getRawUserInfo()==null&&uri.getQuery()==null&&uri.getFragment()==null&&(uri.getPort()==-1||uri.getPort()==443));
    String path=uri.getPath();
    SyncCrypto.require(path==null||path.isEmpty()||path.equals("/"));
    return new URI("https",null,uri.getHost(),uri.getPort(),null,null,null).toString();
  }
  static final class HTTPFailure extends IOException{
    final int status;
    final String serverCode;
    HTTPFailure(int status,String code){
      super(status==429?"接入尝试过多，请稍后再试":status==404||status==410?"接入码已过期或仍在等待原设备授权":"同步服务器返回 "+status);
      this.status=status;
      this.serverCode=code;
    }
  }
  private JSONObject request(String endpoint,String method,String path,JSONObject json)throws Exception{
    if(transport!=null)return transport.request(endpoint,method,path,json);
    HttpsURLConnection c=(HttpsURLConnection)new URL(endpoint+path).openConnection();
    c.setInstanceFollowRedirects(false);
    c.setConnectTimeout(15000);
    c.setReadTimeout(20000);
    c.setUseCaches(false);
    c.setRequestMethod(method);
    c.setRequestProperty("Content-Type","application/json");
    c.setRequestProperty("Accept","application/json");
    byte[] body=json.toString().getBytes(SyncCrypto.UTF8);
    c.setDoOutput(true);
    c.setFixedLengthStreamingMode(body.length);
    try{
      try(OutputStream o=c.getOutputStream()){
        o.write(body);
      }
      int status=c.getResponseCode();
      if(status!=200){
        String code="";
        try(InputStream error=c.getErrorStream()){
          if(error!=null){
            ByteArrayOutputStream small=new ByteArrayOutputStream();
            byte[] buffer=new byte[1024];
            int n;
            while((n=error.read(buffer))>0&&small.size()+n<=4096)small.write(buffer,0,n);
            String value=new JSONObject(SyncCrypto.utf8(small.toByteArray())).optString("error");
            if(value.matches("[a-z_]{1,40}"))code=value;
          }
        }
        catch(Exception ignored){
        }
        throw new HTTPFailure(status,code);
      }
      if(c.getContentLengthLong()>4*1024*1024)throw new IOException("同步响应过大");
      ByteArrayOutputStream b=new ByteArrayOutputStream();
      try(InputStream input=c.getInputStream()){
        byte[] buffer=new byte[16384];
        int n;
        while((n=input.read(buffer))!=-1){
          if(b.size()+n>4*1024*1024)throw new IOException("同步响应过大");
          b.write(buffer,0,n);
        }
      }
      return LosslessJson.object(SyncCrypto.utf8(b.toByteArray()),4*1024*1024);
    }
    finally{
      c.disconnect();
    }
  }
  private JSONObject rpc(String group,int op,JSONObject body,boolean owner)throws Exception{
    return request(state.getString("endpoint"),"POST","/v1/groups/"+SyncCrypto.id(group)+"/rpc",SyncCrypto.request(identity(),group,op,body==null?new byte[0]:SyncCrypto.bytes(LosslessJson.canonical(body)),owner,now()));
  }
  private String group()throws Exception{
    return state.getJSONObject("membership").getString("group");
  }
  boolean connected(){
    return state.has("membership")&&state.has("groupKey");
  }
  boolean joining(){return state.has("joining")&&state.has("pair");}
  boolean joiningExpired(){return joining()&&joiningDeadline()<=now();}
  long joiningDeadline(){return state.optLong("waitingUntil",state.optJSONObject("pair")==null?0:state.optJSONObject("pair").optLong("expiresAt",0));}
  String departureReason(){return state.optString("departed","");}
  String endpoint(){
    return state.optString("endpoint","");
  }
  int members()throws Exception{
    return connected()?state.getJSONObject("membership").getJSONArray("members").length():0;
  }
  boolean learning(){
    return prefs.getBoolean("learning",false);
  }
  boolean clipboard(){
    return prefs.getBoolean("clipboard",false);
  }
  void consent(boolean learning,boolean clipboard){
    synchronized(CONSENT_LOCK){
      prefs.edit().putLong("generation",prefs.getLong("generation",0)+1).putBoolean("learning",learning).putBoolean("clipboard",clipboard).commit();
    }
  }
  private boolean permitted(int domain,long generation){
    try{
      return connected()&&(SyncCrypto.find(state.getJSONObject("membership"),state.getJSONObject("identity").getString("device")).getInt("permissions")&domain)!=0&&prefs.getLong("generation",0)==generation&&prefs.getBoolean(domain==1?"learning":"clipboard",false);
    }
    catch(Exception invalid){
      return false;
    }
  }
  void join(String code,String server)throws Exception{
    SyncCrypto.require(!connected()&&code.matches("[0-9]{6}"));
    server=endpoint(server);
    JSONObject pair;
    if(state.optString("pendingCode").equals(code)&&state.optString("endpoint").equals(server)&&state.has("pair")&&state.getJSONObject("pair").getLong("expiresAt")>now())pair=state.getJSONObject("pair");
    else pair=SyncCrypto.pair(identity(),now());
    state.put("endpoint",server).put("pendingCode",code).put("pair",pair);
    save();
    JSONObject response=request(server,"POST","/v1/pairing/claim",new JSONObject().put("code",code).put("request",pair));
    acceptInvitation(response.getJSONObject("invitation"),server);
  }
  private void acceptInvitation(JSONObject invitation,String server)throws Exception{
    SyncCrypto.require(invitation.getInt("version")==1&&endpoint(invitation.getString("endpoint")).equals(server)&&SyncCrypto.data(invitation.getJSONObject("anchor"),"ownerPublic").length==32);
    state.put("joining",invitation).put("waitingUntil",Math.min(state.getJSONObject("pair").getLong("expiresAt"),now()+120));
    save();
  }
  void cancelJoining()throws Exception{
    SyncCrypto.require(!connected());
    state.remove("joining");
    state.remove("pair");state.remove("waitingUntil");
    state.remove("pendingCode");
    state.remove("pendingQR");
    save();
  }
  void joinQR(String link)throws Exception{
    SyncCrypto.require(!connected()&&link.length()<=10000);
    URI url=new URI(link);
    SyncCrypto.require("privateinput".equals(url.getScheme())&&"pair".equals(url.getHost())&&url.getFragment()==null&&url.getUserInfo()==null);
    String query=url.getRawQuery();
    SyncCrypto.require(query!=null&&query.startsWith("data=")&&!query.contains("&"));
    JSONObject qr=SyncCrypto.decodeQRQuery(query.substring(5));
    SyncCrypto.require(qr.getLong("expiresAt")>now()&&qr.getLong("expiresAt")-now()<=300&&SyncCrypto.data(qr,"secret").length==32);
    String server=endpoint(qr.getJSONObject("invitation").getString("endpoint"));
    JSONObject pair=state.optString("pendingQR").equals(link)&&state.has("pair")&&state.getJSONObject("pair").getLong("expiresAt")>now()?state.getJSONObject("pair"):SyncCrypto.pair(identity(),now());
    state.put("endpoint",server).put("pair",pair).put("pendingQR",link);
    save();
    JSONObject result=request(server,"POST","/v1/pairing/claim",new JSONObject().put("ticket",qr.getString("ticket")).put("secret",qr.getString("secret")).put("request",pair));
    SyncCrypto.require(LosslessJson.canonical(result.getJSONObject("invitation").getJSONObject("anchor")).equals(LosslessJson.canonical(qr.getJSONObject("invitation").getJSONObject("anchor"))));
    acceptInvitation(result.getJSONObject("invitation"),server);
  }
  private void pollJoin()throws Exception{
    JSONObject pair=state.getJSONObject("pair"),anchor=state.getJSONObject("joining").getJSONObject("anchor");
    if(joiningDeadline()<=now())throw new IOException("连接已超时，请重新扫码或输入新的接入码");
    SyncCrypto.live(pair,now());
    String group=anchor.getString("group");
    JSONObject template=rpc(group,6,new JSONObject().put("session",pair.getString("session")),false).getJSONObject("challenge").getJSONObject("template");
    SyncCrypto.require(template.getInt("purpose")==1&&SyncCrypto.data(template,"sealedKey").length==0&&template.getJSONObject("membership").getString("signature").isEmpty()&&Arrays.equals(SyncCrypto.data(template,"context"),SyncCrypto.sha(SyncCrypto.canonicalPair(pair)))&&template.getLong("expiresAt")<=pair.getLong("expiresAt"));
    SyncCrypto.live(template,now());
    JSONObject proposed=template.getJSONObject("membership"),recipient=SyncCrypto.find(proposed,identity().getString("device"));
    SyncCrypto.require(LosslessJson.canonical(SyncCrypto.anchor(proposed)).equals(LosslessJson.canonical(anchor))&&recipient.getString("signingPublic").equals(identity().getString("signingPublic"))&&recipient.getString("exchangePublic").equals(identity().getString("exchangePublic")));
    JSONObject proposal=template.getJSONObject("membership");
    if(proposal.getInt("version")==2){JSONArray history=proposal.getJSONArray("history");JSONObject parent=new JSONObject(history.getJSONObject(history.length()-1).toString());if(parent.getInt("version")==2){JSONArray before=new JSONArray();for(int i=0;i<history.length()-1;i++)before.put(history.get(i));parent.put("history",before);}SyncCrypto.verifyMembership(parent,anchor,null);SyncCrypto.require(Arrays.equals(SyncCrypto.data(proposal,"parent"),SyncCrypto.sha(SyncCrypto.membership(parent))));}
    SyncCrypto.verify(SyncCrypto.wrappedHeader(template),SyncCrypto.data(template,"signature"),SyncCrypto.authorizationPublic(proposal));
    JSONObject pack=rpc(group,4,null,false).getJSONObject("package");
    SyncCrypto.require(Arrays.equals(SyncCrypto.wrappedHeader(template),SyncCrypto.wrappedHeader(pack)));
    byte[] key=SyncCrypto.openKey(pack,identity(),anchor,null,SyncCrypto.sha(SyncCrypto.canonicalPair(pair)),now());
    state.put("membership",pack.getJSONObject("membership")).put("groupKey",SyncCrypto.b64(key)).put("anchor",anchor);
    state.remove("joining");state.remove("pair");state.remove("pendingCode");state.remove("pendingQR");state.remove("departed");
    state.remove("profileRegistered");state.put("privacyEpoch",PersonalReset.generation(context));
    save();
  }
  private void refreshMembership()throws Exception{
    JSONObject old=state.getJSONObject("membership"),m=rpc(group(),1,null,false).getJSONObject("membership");
    SyncCrypto.verifyMembership(m,state.getJSONObject("anchor"),old);
    SyncCrypto.find(m,identity().getString("device"));
    if(!Arrays.equals(SyncCrypto.membership(old),SyncCrypto.membership(m))){
      JSONObject pack=rpc(group(),4,null,false).getJSONObject("package");
      SyncCrypto.require(Arrays.equals(SyncCrypto.membership(m),SyncCrypto.membership(pack.getJSONObject("membership"))));
      byte[] key=SyncCrypto.openKey(pack,identity(),state.getJSONObject("anchor"),old,new byte[32],now());
      retainUnsent();holdPendingForRotation();
      state.put("membership",m).put("groupKey",SyncCrypto.b64(key));
      state.remove("publishedDigest");
      save();
    }
  }
  private JSONObject reserve(byte[] payload,int domain)throws Exception{
    BigInteger n=SyncCrypto.u(state,"sequence").add(BigInteger.ONE);
    SyncCrypto.require(n.compareTo(LosslessJson.UINT64_MAX)<=0);
    state.put("sequence",n);
    save();
    return SyncCrypto.seal(payload,domain,state,now());
  }
  String automaticClipboardScope()throws Exception{
    long generation=prefs.getLong("generation",0);
    if(!prefs.getBoolean(AutoClipboardBridge.ENABLED,false)||!permitted(2,generation))return "";
    byte[] membership=SyncCrypto.membership(state.getJSONObject("membership"));
    String flags=generation+":"+prefs.getLong(AutoClipboardBridge.GENERATION,0)+":"+PersonalReset.generation(context)+":"+state.getJSONObject("identity").getString("device");
    return SyncCrypto.b64(SyncCrypto.sha(SyncCrypto.concat(membership,SyncCrypto.bytes(flags))));
  }
  void queueAutomaticText(String text,String expectedScope)throws Exception{
    SyncCrypto.require(AutoClipboardState.eligible(text));refreshMembership();
    synchronized(CONSENT_LOCK){
      SyncCrypto.require(!expectedScope.isEmpty()&&expectedScope.equals(automaticClipboardScope()));
      JSONArray outbox=state.getJSONArray("outbox");SyncCrypto.require(outbox.length()<32);
      JSONObject envelope=reserve(SyncCrypto.bytes(text),2);
      outbox.put(new JSONObject().put("wire",envelope).put("generation",prefs.getLong("generation",0)).put("automaticGeneration",prefs.getLong(AutoClipboardBridge.GENERATION,0)));
      save();
    }
  }
  void sendText(String text)throws Exception{
    SyncCrypto.require(connected()&&clipboard()&&!text.isEmpty()&&SyncCrypto.bytes(text).length<=65536&&text.indexOf('\0')<0);
    refreshMembership();
    JSONArray outbox=state.getJSONArray("outbox");
    SyncCrypto.require(outbox.length()<32);
    JSONObject envelope=reserve(SyncCrypto.bytes(text),2);
    outbox.put(new JSONObject().put("wire",envelope).put("generation",prefs.getLong("generation",0)));
    save();
    flushOutbox();
  }
  private void flushOutbox()throws Exception{
    JSONArray out=state.getJSONArray("outbox");
    while(out.length()>0){
      JSONObject row=out.getJSONObject(0),wire=row.getJSONObject("wire");
      int domain=wire.getInt("domain");
      long generation=row.getLong("generation");
      if(!permitted(domain,generation)||(row.has("automaticGeneration")&&(!prefs.getBoolean(AutoClipboardBridge.ENABLED,false)||row.getLong("automaticGeneration")!=prefs.getLong(AutoClipboardBridge.GENERATION,0)))){
        out.remove(0);
        save();
        continue;
      }
      if(wire.getLong("expiresAt")<=now()){
        out.remove(0);
        save();
        continue;
      }
      if(!SyncCrypto.u(wire,"epoch").equals(SyncCrypto.u(state.getJSONObject("membership"),"epoch")))throw new IOException("设备组已变化，有尚未发送的内容。请在共享文本中重新发送");
      byte[] membership=SyncCrypto.membership(state.getJSONObject("membership"));
      String privacyEpoch=PersonalReset.generation(context);
      synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);SyncCrypto.require(permitted(domain,generation));
        SyncCrypto.require(!row.has("automaticGeneration")||(prefs.getBoolean(AutoClipboardBridge.ENABLED,false)&&row.getLong("automaticGeneration")==prefs.getLong(AutoClipboardBridge.GENERATION,0)));}
      JSONObject response=request(state.getString("endpoint"),"POST","/v1/groups/"+group()+"/events",wire);
      synchronized(CONSENT_LOCK){
        checkPass(generation,membership,privacyEpoch);SyncCrypto.require(permitted(domain,generation));
        SyncCrypto.require(response.optBoolean("accepted")&&SyncCrypto.id(response.getString("event")).equals(SyncCrypto.id(wire.getString("event"))));
        out.remove(0);
        save();
      }
    }
  }
  private static final String[] INCOMING_KEYS={"pendingIncoming","pendingLearningIncoming","pendingClipboardIncoming"};
  private void retireInvalidPendingConsent()throws Exception{
    boolean changed=false;
    for(String key:INCOMING_KEYS)if(state.has(key)){
      JSONObject pending=state.getJSONObject(key),wire=pending.getJSONObject("wire");
      if(!permitted(wire.getInt("domain"),pending.getLong("generation"))){state.remove(key);changed=true;}
    }
    if(changed)save();
  }
  private void holdPendingForRotation()throws Exception{
    JSONObject held=state.optJSONObject("heldIncoming");if(held==null)held=new JSONObject();
    for(String key:INCOMING_KEYS)if(state.has(key)){
      JSONObject row=state.getJSONObject(key);String event=SyncCrypto.id(row.getJSONObject("wire").getString("event"));
      if(held.has(event))SyncCrypto.require(LosslessJson.canonical(held.get(event)).equals(LosslessJson.canonical(row)));
      else{SyncCrypto.require(held.length()<8);held.put(event,row);}
      state.remove(key);
    }
    if(held.length()>0)state.put("heldIncoming",held);
    state.remove("automaticSyncPhaseScope");state.remove("automaticSyncNextDomain");
  }
  private boolean priorityWindowSafe(JSONArray events)throws Exception{
    JSONObject ledger=state.getJSONObject("ledger");
    for(int i=0;i<events.length();i++){
      JSONObject wire=events.getJSONObject(i);
      SyncCrypto.require(SyncCrypto.id(wire.getString("group")).equals(SyncCrypto.id(group()))&&SyncCrypto.u(wire,"epoch").equals(SyncCrypto.u(state.getJSONObject("membership"),"epoch")));
      String key=SyncCrypto.id(wire.getString("group"))+"/"+SyncCrypto.u(wire,"epoch")+"/"+SyncCrypto.id(wire.getString("sender"));JSONObject window=ledger.optJSONObject(key);
      if(window==null||!ReplayAdvancePolicy.permits(SyncCrypto.u(window,"highest"),Long.parseUnsignedLong(window.getString("bitmap"),16),SyncCrypto.u(wire,"sequence")))return false;
    }
    return true;
  }
  private static final class ReceivedSequence extends IOException {}
  private String receiveDigest(JSONObject wire)throws Exception{
    return SyncCrypto.b64(SyncCrypto.sha(SyncCrypto.concat(SyncCrypto.eventHeader(wire),SyncCrypto.data(wire,"ciphertext"))));
  }
  private void checkPass(long generation,byte[] membership,String privacyEpoch)throws Exception{
    SyncCrypto.require(connected()&&prefs.getLong("generation",0)==generation&&(learning()||clipboard())
      &&privacyEpoch.equals(PersonalReset.generation(context))
      &&Arrays.equals(membership,SyncCrypto.membership(state.getJSONObject("membership"))));
  }
  private JSONObject accepting(JSONObject wire)throws Exception{
    JSONObject all=new JSONObject(state.getJSONObject("ledger").toString());
    String id=SyncCrypto.id(wire.getString("group"))+"/"+SyncCrypto.u(wire,"epoch")+"/"+SyncCrypto.id(wire.getString("sender"));
    JSONObject window=all.optJSONObject(id);
    BigInteger sequence=SyncCrypto.u(wire,"sequence");
    long bitmap=1;
    if(window!=null){
      BigInteger high=SyncCrypto.u(window,"highest");
      long old=Long.parseUnsignedLong(window.getString("bitmap"),16);
      int diff=sequence.subtract(high).max(BigInteger.valueOf(-65)).min(BigInteger.valueOf(65)).intValue();
      if(diff>0)bitmap=diff>=64?1:(old<<diff)|1;
      else{
        if(diff<=-64||(old&(1L<<-diff))!=0)throw new ReceivedSequence();
        bitmap=old|(1L<<-diff);
        sequence=high;
      }
    }
    all.put(id,new JSONObject().put("highest",sequence).put("bitmap",Long.toUnsignedString(bitmap,16)));
    return all;
  }
  private void applyPending(int domains)throws Exception{
    for(String key:INCOMING_KEYS){
      if(state.has(key)&&(state.getJSONObject(key).getJSONObject("wire").getInt("domain")&domains)!=0)applyPending(key);
    }
  }
  private void applyPending(String pendingKey)throws Exception{
    synchronized(CONSENT_LOCK){
      if(!state.has(pendingKey))return;
      JSONObject pending=state.getJSONObject(pendingKey),wire=pending.getJSONObject("wire");
      int domain=wire.getInt("domain");
      long generation=pending.getLong("generation");
      if(!permitted(domain,generation)){
        state.remove(pendingKey);
        save();
        return;
      }
      SyncCrypto.require(SyncCrypto.id(wire.getString("group")).equals(SyncCrypto.id(group()))
        &&SyncCrypto.u(wire,"epoch").equals(SyncCrypto.u(state.getJSONObject("membership"),"epoch")));
      // Stage the complete receipt/ledger/inbox together. A failed atomic save
      // must not leave this SyncClient instance believing a packet persisted.
      JSONObject next=LosslessJson.object(LosslessJson.canonical(state),6*1024*1024);
      byte[] payload=SyncCrypto.data(pending,"payload");
      if(domain==1){
        String text=SyncCrypto.utf8(payload);
        LearningModel merged=new LearningModel();
        merged.merge(text);
        new LearningSnapshotFile(new File(context.getFilesDir(),"Shared")).publish(text);
        String personal=merged.personalSnapshot();
        if(personal!=null)new PersonalLexicon(new File(context.getFilesDir(),"Shared")).mergeSynchronized(personal);
        PersonalChangeSignal.notifyChanged(context);
      }
      else{
        String text=SyncCrypto.utf8(payload);
        SyncCrypto.require(!text.isEmpty()&&text.indexOf('\0')<0&&Arrays.equals(payload,SyncCrypto.bytes(text)));
        JSONArray inbox=next.getJSONArray("inbox");
        boolean exists=false;
        for(int i=0;i<inbox.length();i++)exists|=inbox.getJSONObject(i).getString("event").equals(wire.getString("event"));
        if(!exists)inbox.put(new JSONObject().put("event",wire.getString("event")).put("sender",wire.getString("sender")).put("text",text).put("expiresAt",wire.get("expiresAt")));
        while(inbox.length()>24)inbox.remove(0);
      }
      // A consent change during file application must not acknowledge the packet.
      if(!permitted(domain,generation)){
        state.remove(pendingKey);
        save();
        return;
      }
      // Another domain may have committed while this journal was deferred.
      // Rebase against the current replay window; never restore an old bitmap.
      JSONObject currentLedger;
      try{currentLedger=accepting(wire);}catch(ReceivedSequence alreadyReceived){currentLedger=state.getJSONObject("ledger");}
      next.put("ledger",currentLedger);
      JSONObject receipts=next.optJSONObject("receiveReceipts");
      if(receipts==null){receipts=new JSONObject();next.put("receiveReceipts",receipts);}
      receipts.put(SyncCrypto.id(wire.getString("event")),receiveDigest(wire));
      while(receipts.length()>256)receipts.remove(receipts.keys().next());
      next.remove(pendingKey);
      // Old UUID-only ack lists lacked consent/domain binding. Re-fetch each
      // envelope normally instead of sending an unvalidated bulk acknowledgment.
      next.remove("acks");
      store.save(next);
      state=next;
    }
  }
  JSONArray inbox()throws Exception{
    JSONArray valid=new JSONArray(),all=state.getJSONArray("inbox");
    for(int i=0;i<all.length();i++)if(all.getJSONObject(i).getLong("expiresAt")>now())valid.put(all.getJSONObject(i));
    if(valid.length()!=all.length()){
      state.put("inbox",valid);
      save();
    }
    JSONArray presentation=new JSONArray();for(int n=0;n<valid.length();n++)presentation.put(valid.get(n));
    try{JSONArray live=new ClipboardLiveStore(context).inbox();Set<String> shown=new HashSet<>(),historic=new HashSet<>();for(int n=0;n<presentation.length();n++){JSONObject old=presentation.getJSONObject(n);String event=SyncCrypto.id(old.getString("event"));if(old.has("sender"))shown.add(SyncCrypto.id(old.getString("sender"))+"/"+event);else historic.add(event);}for(int n=0;n<live.length();n++){JSONObject value=live.getJSONObject(n);String event=SyncCrypto.id(value.getString("event"));if(!historic.contains(event)&&shown.add(SyncCrypto.id(value.getString("sender"))+"/"+event))presentation.put(value);}}catch(Exception unavailable){}
    return presentation;
  }
  private void forwardLiveCompatibility(String scope)throws Exception{
    ClipboardLiveStore live=new ClipboardLiveStore(context);JSONObject snapshot=live.snapshot(),credential=snapshot.optJSONObject("credential");if(scope.isEmpty()||!live.authorized(credential)||!scope.equals(credential.getString("scope")))return;
    JSONArray pending=snapshot.getJSONArray("compatibility");JSONObject copy=null;for(int n=0;n<pending.length();n++)if(pending.getJSONObject(n).getLong("expiresAt")>now()){copy=pending.getJSONObject(n);break;}if(copy==null)return;String event=SyncCrypto.id(copy.getString("event"));
    synchronized(CONSENT_LOCK){SyncCrypto.require(scope.equals(automaticClipboardScope()));JSONArray known=state.optJSONArray("clipboardLiveCompatibilityQueued");if(known==null){known=new JSONArray();state.put("clipboardLiveCompatibilityQueued",known);}boolean exists=false;for(int n=0;n<known.length();n++)exists|=event.equals(known.getString(n));
     if(!exists){SyncCrypto.require(state.getJSONArray("outbox").length()<32);java.math.BigInteger sequence=SyncCrypto.u(state,"sequence").add(java.math.BigInteger.ONE);SyncCrypto.require(sequence.compareTo(LosslessJson.UINT64_MAX)<=0);state.put("sequence",sequence);JSONObject wire=SyncCrypto.seal(SyncCrypto.bytes(copy.getString("text")),2,state,now(),event,copy.getLong("expiresAt"));state.getJSONArray("outbox").put(new JSONObject().put("wire",wire).put("generation",prefs.getLong("generation",0)).put("automaticGeneration",prefs.getLong(AutoClipboardBridge.GENERATION,0)));known.put(event);while(known.length()>256)known.remove(0);save();}
     live.change(s->{SyncCrypto.require(live.authorized(s.optJSONObject("credential"))&&ClipboardLiveStore.sameCredential(credential,s.optJSONObject("credential")));JSONArray current=s.getJSONArray("compatibility");for(int n=current.length()-1;n>=0;n--)if(event.equals(SyncCrypto.id(current.getJSONObject(n).getString("event"))))current.remove(n);return null;});
    }
  }
  void synchronize()throws Exception{synchronize(0);}
  void synchronizeAutomatic(boolean learningTurn)throws Exception{synchronize(learningTurn?1:2);}
  private void synchronize(int preferredAutomaticDomain)throws Exception{
    finishRegistration();
    if(connected()){refreshDeviceStatus();if(!connected())return;}
    finishGrant();
    if(joining()){
      try{
        pollJoin();
      }
      catch(HTTPFailure waiting){
        if(waiting.status!=403&&waiting.status!=404)throw waiting;
        pairingWait=waiting.serverCode+":"+waiting.status;
      }
      return;
    }
    if(!connected())return;
    refreshMembership();
    pruneInactive();
    approveQuickClaims();
    synchronized(CONSENT_LOCK){retireInvalidPendingConsent();}
    String automaticScope=automaticClipboardScope();
    try{ClipboardLiveAuthority.refresh(context,state,automaticScope,this::save,(path,body)->request(state.getString("endpoint"),"POST",path,body));forwardLiveCompatibility(automaticScope);}catch(Exception unavailable){/* Optional live lane never disables original relay sync. */}
    long generation=prefs.getLong("generation",0);
    int allowedMask=(learning()?1:0)|(clipboard()?2:0);
    if(allowedMask==0)return;
    int mask=SyncPhasePolicy.choose(allowedMask,!automaticScope.isEmpty(),automaticScope,state.optString("automaticSyncPhaseScope"),state.optInt("automaticSyncNextDomain",2));
    if(!automaticScope.isEmpty()&&(preferredAutomaticDomain==1||preferredAutomaticDomain==2)&&(allowedMask&preferredAutomaticDomain)!=0)mask=preferredAutomaticDomain;
    byte[] membership=SyncCrypto.membership(state.getJSONObject("membership"));
    String privacyEpoch=PersonalReset.generation(context);
    synchronized(CONSENT_LOCK){
      checkPass(generation,membership,privacyEpoch);
      // Persist the next turn before I/O so a quota, bad packet or interrupted
      // write in one domain cannot permanently starve the other domain.
      if(allowedMask==3&&!automaticScope.isEmpty()&&automaticScope.equals(automaticClipboardScope())){
        state.put("automaticSyncPhaseScope",automaticScope).put("automaticSyncNextDomain",SyncPhasePolicy.following(mask));save();
      }
      applyPending(mask);
    }
    // Drain at most two verified, durably applied messages before attempting
    // uploads: a full relay must not deadlock behind this device's outbox.
    synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
    AutoClipboardBridge automatic=AutoClipboardBridge.get(context);
    boolean clipboardOutgoing=false;JSONArray automaticOutbox=state.getJSONArray("outbox");for(int index=0;index<automaticOutbox.length();index++)clipboardOutgoing|=automaticOutbox.getJSONObject(index).getJSONObject("wire").getInt("domain")==2;
    AutoClipboardState.Pass automaticPass=!automaticScope.isEmpty()?automatic.beginPass(automaticScope,clipboardOutgoing):null;
    long automaticGeneration=prefs.getLong(AutoClipboardBridge.GENERATION,0);
    ArrayList<AutoClipboardBridge.Incoming> automaticIncoming=new ArrayList<>();
    JSONObject response=rpc(group(),2,new JSONObject().put("limit",2).put("domains",mask),false);
    synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
    JSONArray events=response.getJSONArray("events");
    SyncCrypto.require(events.length()<=2);
    int receiveMask=mask;boolean orderedFallback=false;
    if(!automaticScope.isEmpty()&&mask!=3){
      for(int i=0;i<events.length();i++)SyncCrypto.require((events.getJSONObject(i).getInt("domain")&mask)!=0);
      synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);orderedFallback=!priorityWindowSafe(events);}
      if(orderedFallback){
        // At most one extra read, still only two durable receives. Do not ACK
        // the preview or let it advance/evict the other domain's old sequence.
        synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
        response=rpc(group(),2,new JSONObject().put("limit",2).put("domains",allowedMask),false);
        synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);applyPending(allowedMask);}
        events=response.getJSONArray("events");SyncCrypto.require(events.length()<=2);receiveMask=allowedMask;
      }
    }
    JSONArray completedAcks=new JSONArray();
    for(int i=0;i<events.length();i++){
      JSONObject wire=events.getJSONObject(i);
      int domain=wire.getInt("domain");
      synchronized(CONSENT_LOCK){
        checkPass(generation,membership,privacyEpoch);
        SyncCrypto.require((domain&receiveMask)!=0&&permitted(domain,generation));
        byte[] payload=SyncCrypto.open(wire,state.getJSONObject("membership"),SyncCrypto.data(state,"groupKey"),now());
        JSONObject ledger;
        JSONObject receipts=state.optJSONObject("receiveReceipts");
        String persisted=receipts==null?"":receipts.optString(SyncCrypto.id(wire.getString("event")));
        boolean duplicate=!persisted.isEmpty();
        if(duplicate){
          SyncCrypto.require(persisted.equals(receiveDigest(wire)));
          ledger=state.getJSONObject("ledger");
        }
        else try{ledger=accepting(wire);}
        catch(ReceivedSequence replay){
          ledger=state.getJSONObject("ledger");
          // Pre-upgrade replay ledgers had no exact receipt. Reapply the
          // idempotent payload and persist a receipt before acknowledging it.
        }
        if(!duplicate){
          if(domain==1){LearningModel validation=new LearningModel();validation.merge(SyncCrypto.utf8(payload));}
          String pendingKey=domain==1?"pendingLearningIncoming":"pendingClipboardIncoming";
          state.put(pendingKey,new JSONObject().put("wire",wire).put("payload",SyncCrypto.b64(payload)).put("ledger",ledger).put("generation",generation));
          save();
          applyPending(receiveMask);
        }
        checkPass(generation,membership,privacyEpoch);
        SyncCrypto.require(permitted(domain,generation)&&state.getJSONObject("receiveReceipts").getString(SyncCrypto.id(wire.getString("event"))).equals(receiveDigest(wire)));
        if(domain==2)automaticIncoming.add(new AutoClipboardBridge.Incoming(wire.getString("sender"),wire.getString("event"),SyncCrypto.utf8(payload),wire.getLong("expiresAt"),SyncCrypto.id(wire.getString("sender")).equals(SyncCrypto.id(state.getJSONObject("identity").getString("device")))));
      }
      completedAcks.put(wire.getString("event"));
    }
    if(completedAcks.length()>0){
      // At most one ACK request per pass, and only for this pass's verified,
      // durably received envelopes. No consent lock is held over the request.
      synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
      SyncCrypto.require(rpc(group(),3,new JSONObject().put("events",completedAcks),false).optBoolean("accepted"));
      synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
    }
    synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
    if(automaticPass!=null&&!new ClipboardLiveStore(context).available()&&(mask==2||!automaticIncoming.isEmpty()))automatic.completedPass(automaticPass,automaticIncoming,!orderedFallback&&SyncPhasePolicy.clipboardDrained(mask,events.length()),generation,automaticGeneration,privacyEpoch);
    flushOutbox();
    synchronized(CONSENT_LOCK){checkPass(generation,membership,privacyEpoch);}
    if((mask&1)!=0&&learning()&&permitted(1,generation)&&!new LearningCoordinator(context.getFilesDir(),new File(context.getFilesDir(),"Shared")).requiresPrivateRecovery()){
      LearningModel export=new LearningModel();
      File shared=new File(context.getFilesDir(),"Shared");
      String current=new LearningSnapshotFile(shared).read();
      if(current!=null)export.merge(current);
      File checkpoint=new File(context.getFilesDir(),"learning-checkpoint-v1.json");
      if(checkpoint.isFile())export.merge(RimeCheckpoint.decode(AppFiles.read(checkpoint,RimeCheckpoint.MAX_STATE_BYTES)).model.export());
      export.mergePersonalLexicon(new PersonalLexicon(shared).synchronizationSnapshot());
      String text=export.export(),digest=SyncCrypto.b64(SyncCrypto.sha(SyncCrypto.bytes(text)));
      String publication=group()+"/"+state.getJSONObject("membership").get("epoch")+"/"+digest;
      if(!publication.equals(state.optString("publishedDigest"))&&permitted(1,generation)){
        synchronized(CONSENT_LOCK){
          checkPass(generation,membership,privacyEpoch);SyncCrypto.require(permitted(1,generation));
          JSONObject wire=reserve(SyncCrypto.bytes(text),1);
          state.getJSONArray("outbox").put(new JSONObject().put("wire",wire).put("generation",generation));
          save();
        }
        flushOutbox();
        synchronized(CONSENT_LOCK){
          checkPass(generation,membership,privacyEpoch);SyncCrypto.require(permitted(1,generation));
          state.put("publishedDigest",publication);
          save();
        }
      }
    }
    if((mask&1)!=0&&learning()&&permitted(1,generation)){
      try{new RecentLearningSync(context,state,(path,body)->request(state.getString("endpoint"),"POST",path,body),()->permitted(1,generation),this::save).synchronize();}
      catch(Exception unsupportedOrUnavailable){/* v1 and clipboard already completed; recency stays cumulative-only. */}
    }
  }
  void disconnect()throws Exception{
    consent(false,false);
    save();
  }
  JSONObject ticket()throws Exception{
    return state.optJSONObject("ticket");
  }
  JSONObject invite()throws Exception{
    SyncCrypto.require(connected());
    refreshMembership();
    SyncCrypto.require(SyncCrypto.find(state.getJSONObject("membership"),identity().getString("device")).getInt("permissions")==3);
    JSONObject anchor=state.getJSONObject("anchor"),invitation=new JSONObject().put("version",1).put("endpoint",state.getString("endpoint")).put("anchor",anchor);
    String id=SyncCrypto.id();
    byte[] secret=SyncCrypto.random(32);
    JSONObject ticket=rpc(group(),8,new JSONObject().put("ticket",id).put("secretHash",SyncCrypto.b64(SyncCrypto.sha(secret))).put("invitation",invitation).put("expiresAt",now()+290),false);
    SyncCrypto.require(ticket.getString("ticket").equals(id)&&ticket.getString("code").matches("[0-9]{6}")&&ticket.getLong("expiresAt")>now()&&ticket.getLong("expiresAt")<=now()+300);
    JSONObject qr=new JSONObject().put("invitation",invitation).put("ticket",id).put("secret",SyncCrypto.b64(secret)).put("expiresAt",ticket.get("expiresAt"));
    ticket.put("link","privateinput://pair?data="+URLEncoder.encode(SyncCrypto.encodeQR(qr),"UTF-8"));
    state.put("ticket",ticket);
    save();
    return ticket;
  }
  void closeTicket()throws Exception{
    if(state.has("ticket")){
      SyncCrypto.require(rpc(group(),10,new JSONObject().put("ticket",state.getJSONObject("ticket").getString("ticket")),false).optBoolean("accepted"));
      state.remove("ticket");
      save();
    }
  }
  void createGroup(String server)throws Exception{
    SyncCrypto.require(!connected()&&!joining());
    JSONObject m=SyncCrypto.newMembership(identity());
    state.remove("departed");state.put("privacyEpoch",PersonalReset.generation(context));
    state.put("endpoint",endpoint(server)).put("membership",m).put("anchor",SyncCrypto.anchor(m)).put("groupKey",SyncCrypto.b64(SyncCrypto.random(32))).put("registering",true);
    save();
    finishRegistration();
  }
  private void finishRegistration()throws Exception{
    if(!state.optBoolean("registering"))return;
    try{
      SyncCrypto.require(request(state.getString("endpoint"),"POST","/v1/groups",state.getJSONObject("membership")).optBoolean("accepted"));
    }
    catch(HTTPFailure failure){
      if(failure.status!=409)throw failure;
      JSONObject remote=rpc(group(),1,null,false).getJSONObject("membership");
      SyncCrypto.verifyMembership(remote,state.getJSONObject("anchor"),state.getJSONObject("membership"));
      SyncCrypto.require(Arrays.equals(SyncCrypto.membership(remote),SyncCrypto.membership(state.getJSONObject("membership"))));
    }
    state.remove("registering");
    save();
  }
  private void approveQuickClaims()throws Exception{
    JSONObject current=state.getJSONObject("membership"),identity=identity();
    if(SyncCrypto.find(current,identity.getString("device")).getInt("permissions")!=3)return;
    JSONArray claims=rpc(group(),9,null,false).getJSONArray("claims");
    SyncCrypto.require(claims.length()<=64);
    if(claims.length()==0)return;
    JSONObject consumed=state.optJSONObject("consumedPairs");
    if(consumed==null){
      consumed=new JSONObject();
      state.put("consumedPairs",consumed);
    }
    ArrayList<String> expired=new ArrayList<>();
    Iterator<String> seen=consumed.keys();
    while(seen.hasNext()){
      String session=seen.next();
      if(consumed.getLong(session)<=now())expired.add(session);
    }
    for(String session:expired)consumed.remove(session);
    JSONObject claim=null;
    for(int n=0;n<claims.length();n++){
      JSONObject item=claims.getJSONObject(n);
      String session=SyncCrypto.id(item.getJSONObject("request").getString("session"));
      if(item.getLong("expiresAt")>now()&&!consumed.has(session)){
        claim=item;
        break;
      }
    }
    if(claim==null)return;
    JSONObject pair=claim.getJSONObject("request"),member=pair.getJSONObject("member");
    SyncCrypto.require(SyncCrypto.id(claim.getString("sponsor")).equals(SyncCrypto.id(identity.getString("device")))&&SyncCrypto.find(current,claim.getString("sponsor")).getInt("permissions")==3&&claim.getLong("expiresAt")>now());
    SyncCrypto.live(pair,now());
    byte[] digest=SyncCrypto.sha(SyncCrypto.canonicalPair(pair));
    SyncCrypto.verify(SyncCrypto.canonicalPair(pair),SyncCrypto.data(pair,"signature"),SyncCrypto.data(member,"signingPublic"));
    JSONArray nextMembers=new JSONArray(current.getJSONArray("members").toString());nextMembers.put(member);
    JSONObject m=SyncCrypto.successor(current,nextMembers,identity);
    byte[] key=SyncCrypto.random(32);
    JSONObject pack=SyncCrypto.wrap(m,member.getString("device"),key,digest,identity,now(),Math.min(pair.getLong("expiresAt"),now()+600));
    JSONObject template=new JSONObject(pack.toString());
    template.put("sealedKey","");
    template.getJSONObject("membership").put("signature","");
    template.put("signature",SyncCrypto.b64(SyncCrypto.sign(SyncCrypto.wrappedHeader(template),SyncCrypto.authorizationKey(m,identity))));
    JSONArray packages=new JSONArray().put(pack);
    JSONArray members=m.getJSONArray("members");
    for(int i=0;i<members.length();i++){
      String device=members.getJSONObject(i).getString("device");
      if(!device.equals(member.getString("device")))packages.put(SyncCrypto.wrap(m,device,key,new byte[32],identity,now(),now()+2592000));
    }
    state.put("grant",new JSONObject().put("phase",0).put("nextKey",0).put("membership",m).put("key",SyncCrypto.b64(key)).put("packages",packages).put("challenge",new JSONObject().put("session",pair.getString("session")).put("challenge",new JSONObject().put("template",template))));
    save();
    finishGrant();
  }
  private void finishGrant()throws Exception{
    if(!state.has("grant"))return;
    JSONObject grant=state.getJSONObject("grant"),m=grant.getJSONObject("membership");
    String path="/v1/groups/"+m.getString("group");
    if(m.getInt("version")==2){
      JSONObject body;
      boolean admission=grant.has("challenge");
      if(admission){JSONObject challenge=grant.getJSONObject("challenge");body=new JSONObject().put("session",challenge.get("session")).put("challenge",challenge.get("challenge")).put("membership",m).put("packages",grant.getJSONArray("packages"));}
      else body=new JSONObject().put("membership",m).put("packages",grant.getJSONArray("packages"));
      JSONArray compact=new JSONArray();JSONArray full=body.getJSONArray("packages");for(int i=0;i<full.length();i++){JSONObject item=new JSONObject(full.getJSONObject(i).toString());item.remove("membership");compact.put(item);}body.put("packages",compact);
      if(admission){JSONObject challenge=new JSONObject(body.getJSONObject("challenge").toString());challenge.getJSONObject("template").remove("membership");body.put("challenge",challenge);}
      try{SyncCrypto.require(request(state.getString("endpoint"),"POST",path+(admission?"/admission":"/change"),body).optBoolean("accepted"));}
      catch(HTTPFailure conflict){if(conflict.status!=409)throw conflict;state.remove("grant");save();refreshMembership();return;}
    }else{throw new IOException("旧版未完成授权需要重新生成接入码");}
    retainUnsent();holdPendingForRotation();
    state.put("membership",m).put("groupKey",grant.getString("key"));
    if(grant.has("challenge")){
      JSONObject consumed=state.optJSONObject("consumedPairs");
      if(consumed==null)consumed=new JSONObject();
      consumed.put(SyncCrypto.id(grant.getJSONObject("challenge").getString("session")),grant.getJSONObject("challenge").getJSONObject("challenge").getJSONObject("template").get("expiresAt"));
      state.put("consumedPairs",consumed);
    }
    state.remove("grant");
    state.remove("publishedDigest");
    save();
  }
  private void retainUnsent()throws Exception{
    JSONArray pending=state.getJSONArray("outbox"),unsent=state.optJSONArray("unsent");
    if(unsent==null)unsent=new JSONArray();
    for(int i=0;i<pending.length();i++){
      JSONObject wire=pending.getJSONObject(i).getJSONObject("wire");
      if(wire.getInt("domain")==2&&wire.getLong("expiresAt")>now()){
        byte[] text=SyncCrypto.open(wire,state.getJSONObject("membership"),SyncCrypto.data(state,"groupKey"),now());
        unsent.put(new JSONObject().put("event",wire.getString("event")).put("text",SyncCrypto.utf8(text)).put("expiresAt",wire.get("expiresAt")));
      }
    }
    while(unsent.length()>24)unsent.remove(0);
    state.put("unsent",unsent).put("outbox",new JSONArray());
  }
  JSONArray unsent()throws Exception{
    JSONArray all=state.optJSONArray("unsent"),valid=new JSONArray();
    if(all==null)return valid;
    for(int n=0;n<all.length();n++)if(all.getJSONObject(n).getLong("expiresAt")>now())valid.put(all.getJSONObject(n));
    if(valid.length()!=all.length()){
      state.put("unsent",valid);
      save();
    }
    return valid;
  }
  void resend(String event)throws Exception{
    JSONArray a=unsent();
    for(int i=0;i<a.length();i++)if(a.getJSONObject(i).getString("event").equals(event)){
      sendText(a.getJSONObject(i).getString("text"));
      a.remove(i);
      state.put("unsent",a);
      save();
      return;
    }
  }
  boolean owner()throws Exception{
    return connected()&&identity().getString("ownerID").equals(state.getJSONObject("anchor").getString("ownerID"));
  }
  JSONArray devices()throws Exception{refreshDeviceStatus();return state.optJSONArray("deviceStatus")==null?new JSONArray():state.getJSONArray("deviceStatus");}
  private void refreshDeviceStatus()throws Exception{
    if(!connected())return;
    if(!state.optBoolean("profileRegistered")){JSONObject prior=rpc(group(),12,null,false);if(prior.optBoolean("departed")){resetForDeparture(prior.optString("reason","removed"));return;}SyncCrypto.require(rpc(group(),11,new JSONObject().put("kind","android"),false).optBoolean("accepted"));state.put("profileRegistered",true).put("privacyEpoch",PersonalReset.generation(context));save();}
    JSONObject status=rpc(group(),12,null,false);
    if(status.optBoolean("departed")){resetForDeparture(status.optString("reason","removed"));return;}
    JSONArray devices=status.getJSONArray("devices");state.put("deviceStatus",devices);
    for(int i=0;i<devices.length();i++){JSONObject item=devices.getJSONObject(i);if(item.optBoolean("isSelf"))prefs.edit().putLong("expires",now()+item.getInt("idleDays")*86400L).commit();}
    save();
  }
  void setIdleDays(int days)throws Exception{SyncCrypto.require(days>=1&&days<=90);SyncCrypto.require(rpc(group(),13,new JSONObject().put("idleDays",days),false).optBoolean("accepted"));refreshDeviceStatus();}
  void leaveGroup()throws Exception{if(connected())SyncCrypto.require(rpc(group(),14,null,false).optBoolean("accepted"));resetForDeparture("left");}
  private void resetForDeparture(String reason)throws Exception{
    consent(false,false);state.put("wipePending",true);save();
    PersonalReset.request(context,reason);String server=state.optString("endpoint");store.resetForDeparture();state=store.load();state.put("endpoint",server).put("departed",reason);save();
  }
  private void pruneInactive()throws Exception{
    JSONArray statuses=state.optJSONArray("deviceStatus");if(statuses==null)return;
    Set<String> departed=new HashSet<>();for(int i=0;i<statuses.length();i++){JSONObject row=statuses.getJSONObject(i);if(row.optBoolean("inactive")&&!row.optBoolean("isSelf"))departed.add(SyncCrypto.id(row.getString("device")));}
    if(departed.isEmpty())return;
    JSONObject current=state.getJSONObject("membership");JSONArray old=current.getJSONArray("members"),members=new JSONArray();
    for(int i=0;i<old.length();i++){JSONObject row=old.getJSONObject(i);if(!departed.contains(SyncCrypto.id(row.getString("device"))))members.put(row);}
    stageMemberChange(current,members);finishGrant();
  }
  private void stageMemberChange(JSONObject current,JSONArray members)throws Exception{
    JSONObject m=SyncCrypto.successor(current,members,identity());byte[] key=SyncCrypto.random(32);JSONArray packages=new JSONArray();
    for(int i=0;i<members.length();i++){String device=members.getJSONObject(i).getString("device");packages.put(SyncCrypto.wrap(m,device,key,new byte[32],identity(),now(),now()+2592000));}
    state.put("grant",new JSONObject().put("phase",1).put("membership",m).put("key",SyncCrypto.b64(key)).put("packages",packages));save();
  }
  void revoke(String device)throws Exception{
    SyncCrypto.require(connected()&&!SyncCrypto.id(device).equals(SyncCrypto.id(identity().getString("device"))));
    refreshDeviceStatus();SyncCrypto.require(connected());
    boolean allowed=false;JSONArray known=state.getJSONArray("deviceStatus");for(int i=0;i<known.length();i++){JSONObject info=known.getJSONObject(i);if(SyncCrypto.id(info.getString("device")).equals(SyncCrypto.id(device)))allowed=info.optString("kind").equals("macos")||info.optString("kind").equals("windows");}SyncCrypto.require(allowed);
    finishGrant();
    refreshMembership();
    JSONObject current=state.getJSONObject("membership"),m=new JSONObject(current.toString());
    JSONArray old=current.getJSONArray("members"),members=new JSONArray();
    boolean removed=false;
    for(int n=0;n<old.length();n++){
      JSONObject member=old.getJSONObject(n);
      if(SyncCrypto.id(member.getString("device")).equals(SyncCrypto.id(device)))removed=true;
      else members.put(member);
    }
    SyncCrypto.require(removed);
    m=SyncCrypto.successor(current,members,identity());
    byte[] key=SyncCrypto.random(32);
    JSONArray packages=new JSONArray();
    for(int n=0;n<members.length();n++){
      String recipient=members.getJSONObject(n).getString("device");
      packages.put(SyncCrypto.wrap(m,recipient,key,new byte[32],identity(),now(),now()+2592000));
    }
    state.put("grant",new JSONObject().put("phase",1).put("nextKey",0).put("membership",m).put("key",SyncCrypto.b64(key)).put("packages",packages));
    save();
    finishGrant();
  }
}
