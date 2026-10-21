package live.linghe.privateinput;
import android.content.*;import java.util.*;import org.json.*;
/** Legacy-actor-only primary operations. Its descriptor contains clipboard keys
 * and a delegate, never the group root or primary private signing material. */
final class ClipboardLiveAuthority {
 interface Save{void run()throws Exception;}
 interface Post{JSONObject run(String path,JSONObject request)throws Exception;}
 static void refresh(Context context,JSONObject state,String scope,Save save,Post post)throws Exception{
  ClipboardLiveStore store=new ClipboardLiveStore(context);SharedPreferences prefs=context.getSharedPreferences("sync-consent",0);long now=System.currentTimeMillis()/1000,initialConsent=prefs.getLong("generation",0),initialAutomatic=prefs.getLong(AutoClipboardBridge.GENERATION,0);String initialPrivacy=PersonalReset.generation(context);
  JSONObject existing=state.optJSONObject("clipboardLiveGrant");store.change(s->{ClipboardLiveStore.retireExpired(s,now);return null;});JSONObject snapshot=store.snapshot(),credential=snapshot.optJSONObject("credential");
  boolean pending=snapshot.getJSONArray("outbox").length()>0;boolean current=!scope.isEmpty()&&store.authorized(credential)&&credential.getString("scope").equals(scope)&&(pending||credential.getJSONObject("delegate").getJSONObject("certificate").getLong("expiresAt")>now+900);
  if(existing!=null&&!current){JSONArray revoke=state.optJSONArray("clipboardLivePendingRevocations");if(revoke==null){revoke=new JSONArray();state.put("clipboardLivePendingRevocations",revoke);}boolean found=false;for(int n=0;n<revoke.length();n++)found|=revoke.getJSONObject(n).getString("generation").equals(existing.getString("generation"));if(!found){SyncCrypto.require(revoke.length()<64);revoke.put(existing);}state.remove("clipboardLiveGrant");save.run();}
  if(scope.isEmpty())store.clearCredential();
  JSONArray revocations=state.optJSONArray("clipboardLivePendingRevocations");
  if(revocations!=null){for(int n=revocations.length()-1,attempts=0;n>=0&&attempts++<2;n--){JSONObject grant=revocations.getJSONObject(n);if(!SyncCrypto.u(grant,"epoch").equals(SyncCrypto.u(state.getJSONObject("membership"),"epoch"))){revocations.remove(n);save.run();continue;}
   JSONObject r=new JSONObject().put("version",1).put("group",grant.get("group")).put("parent",grant.get("parent")).put("epoch",grant.get("epoch")).put("generation",grant.get("generation")).put("issuedAt",now).put("nonce",SyncCrypto.id());byte[] header=SyncCrypto.concat(SyncCrypto.bytes("PrivateInput/clipboard-live-revoke/v1\0"),new byte[]{1},SyncCrypto.uuid(r.getString("group")),SyncCrypto.uuid(r.getString("parent")),SyncCrypto.be(SyncCrypto.u(r,"epoch")),SyncCrypto.uuid(r.getString("generation")),SyncCrypto.be(SyncCrypto.u(r,"issuedAt")),SyncCrypto.uuid(r.getString("nonce")));r.put("signature",SyncCrypto.b64(SyncCrypto.sign(header,SyncCrypto.privateKey("Ed25519",state.getJSONObject("identity").getString("signing")))));
   try{JSONObject reply=post.run("/clipboard-live/v1/revoke",r);SyncCrypto.require(reply.getInt("version")==1&&reply.getBoolean("revoked")&&SyncCrypto.id(reply.getString("generation")).equals(SyncCrypto.id(grant.getString("generation"))));revocations.remove(n);save.run();}catch(Exception unavailable){/* Local closure already fenced. Retry with a fresh parent signature later. */}
  }}
  if(scope.isEmpty()||current)return;
  synchronized(SyncClient.CONSENT_LOCK){SyncCrypto.require(prefs.getLong("generation",0)==initialConsent&&prefs.getLong(AutoClipboardBridge.GENERATION,0)==initialAutomatic&&PersonalReset.generation(context).equals(initialPrivacy));long consent=prefs.getLong("generation",0),automatic=prefs.getLong(AutoClipboardBridge.GENERATION,0);SyncCrypto.require(prefs.getBoolean("clipboard",false)&&prefs.getBoolean(AutoClipboardBridge.ENABLED,false)&&!PersonalReset.expired(context)&&!context.getSharedPreferences("privacy-reset",0).getBoolean("pending",false));
   JSONObject membership=state.getJSONObject("membership"),identity=state.getJSONObject("identity");long issued=Math.max(now,state.optLong("clipboardLiveLastIssuedAt",0)+1),expires=Math.min(issued+ClipboardLiveWire.LEASE,prefs.getLong("expires",issued+ClipboardLiveWire.LEASE));SyncCrypto.require(expires>issued&&issued<=now+300);JSONObject delegate=ClipboardLiveWire.delegate(membership,identity,issued,expires),keys=new JSONObject();JSONArray members=membership.getJSONArray("members");
   for(int n=0;n<members.length();n++){JSONObject member=members.getJSONObject(n);if((member.getInt("permissions")&2)==0)continue;JSONObject domain=new JSONObject().put("group",membership.get("group")).put("sender",member.get("device")).put("epoch",membership.get("epoch")).put("domain",2);keys.put(SyncCrypto.id(member.getString("device")),SyncCrypto.b64(SyncCrypto.eventKey(domain,membership,SyncCrypto.data(state,"groupKey"))));}
   JSONObject c=new JSONObject().put("scope",scope).put("endpoint",state.get("endpoint")).put("membership",membership).put("keys",keys).put("delegate",delegate).put("grant",delegate.getJSONObject("certificate").getString("generation")).put("consent",consent).put("automatic",automatic).put("privacy",PersonalReset.generation(context));SyncCrypto.require(store.authorized(c));
   // Persist primary metadata first; a crash before vault publication causes a
   // new strictly-later grant and leaves the old generation pending revocation.
   state.put("clipboardLiveGrant",delegate.get("certificate")).put("clipboardLiveLastIssuedAt",issued);save.run();store.provision(c);
  }
 }
 private ClipboardLiveAuthority(){}
}
