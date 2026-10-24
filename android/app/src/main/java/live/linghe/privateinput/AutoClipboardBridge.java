package live.linghe.privateinput;
import android.app.KeyguardManager;
import android.content.*;
import android.os.*;
import java.util.*;

/** Clipboard sync is opt-in and separate from activity archiving. Android only
 * allows reads in the foreground or an active non-sensitive default IME. */
final class AutoClipboardBridge {
 static final String ENABLED=ClipboardSyncConsent.AUTOMATIC,GENERATION=ClipboardSyncConsent.AUTOMATIC_GENERATION;
 private static AutoClipboardBridge instance;
 static synchronized AutoClipboardBridge get(Context c){if(instance==null)instance=new AutoClipboardBridge(c.getApplicationContext());return instance;}
 static final class Incoming {
  final String event,text,identity;final long expires;final boolean ownSender;
  Incoming(String sender,String event,String text,long expires,boolean own){this.event=event;identity=UUID.fromString(sender).toString()+"/"+UUID.fromString(event).toString();this.text=text;this.expires=expires;ownSender=own;}
 }
 private final Context context;private final ClipboardManager clipboard;private final SharedPreferences prefs;
 private final Handler main=new Handler(Looper.getMainLooper());private final AutoClipboardState state=new AutoClipboardState();
 private final java.util.concurrent.ExecutorService liveWorker=java.util.concurrent.Executors.newSingleThreadExecutor();private boolean livePolling;private int liveFailures;private volatile boolean liveAvailable;
 private final AutomaticSyncCadence cadence=new AutomaticSyncCadence();
 private final String origin=UUID.randomUUID().toString();private int foreground;private long undatedVersion;private boolean imeSafe,sending,polling;
 private AutoClipboardBridge(Context c){context=c;clipboard=(ClipboardManager)c.getSystemService(Context.CLIPBOARD_SERVICE);prefs=c.getSharedPreferences("sync-consent",0);if(clipboard!=null)try{clipboard.addPrimaryClipChangedListener(()->observe(true));}catch(RuntimeException unavailable){/* Explicit sending remains available in the app. */}}
 // All callers use SyncTasks.worker, including the foreground application.
 void synchronizeActive(SyncClient client)throws Exception{String scope=client.automaticClipboardScope();if(scope.isEmpty())scope=client.automaticLearningScope();client.synchronizeAutomatic(cadence.learningTurn(scope,SystemClock.elapsedRealtime()));}
 long activePollDelay(boolean success){long delay=cadence.pollDelay(success);return success&&liveAvailable?15000:delay;}
 boolean enabled(){return prefs.getBoolean(ENABLED,false);}
 boolean syncEnabled(){return ClipboardSyncConsent.enabled(prefs);}
 private boolean allowed(){return enabled()&&prefs.getBoolean("clipboard",false)&&!PersonalReset.expired(context)&&!context.getSharedPreferences("privacy-reset",0).getBoolean("pending",false);}
 void setEnabled(boolean on){synchronized(SyncClient.CONSENT_LOCK){prefs.edit().putBoolean(ENABLED,on).putLong(GENERATION,prefs.getLong(GENERATION,0)+1).commit();if(!on){liveAvailable=false;long disabled=prefs.getLong(GENERATION,0);liveWorker.execute(()->{try{if(prefs.getLong(GENERATION,0)==disabled&&!enabled())new ClipboardLiveStore(context).clearCredential();}catch(Exception unavailable){/* Preferences already fence every use. */}});}}state.reset("");observe(false);wake();}
 // Preference IO stays on SyncTasks.worker; clipboard APIs stay on the main loop.
 boolean setSyncEnabled(boolean on){
  boolean saved=ClipboardSyncConsent.set(prefs,on);
  if(!on||!saved){liveAvailable=false;long disabled=prefs.getLong(GENERATION,0);liveWorker.execute(()->{try{if(prefs.getLong(GENERATION,0)==disabled&&!enabled())new ClipboardLiveStore(context).clearCredential();}catch(Exception unavailable){/* Consent fences already reject stale work. */}});}
  main.post(()->{state.reset("");observe(false);wake();});
  return saved;
 }
 void foreground(boolean on){foreground=Math.max(0,foreground+(on?1:-1));if(on)observe(false);wake();}
 void imeActive(boolean safe){imeSafe=safe;if(safe)observe(false);wake();}
 // Composition does not pause transport or writes. Only candidate presentation
 // is suppressed while typing; OS access and secure-editor guards stay intact.
 private boolean active(){return foreground>0||imeSafe;}
 private void wake(){main.removeCallbacks(poll);if(imeSafe&&foreground==0&&allowed())main.post(poll);wakeLive();}
 private void wakeLive(){main.removeCallbacks(livePoll);if(active()&&allowed()&&!livePolling)main.post(livePoll);}
 private final Runnable livePoll=this::runLivePoll;
 private void runLivePoll(){if(!active()||!allowed()||livePolling)return;livePolling=true;liveWorker.execute(()->{boolean success=false;try{new ClipboardLiveClient(context).synchronize();liveAvailable=new ClipboardLiveStore(context).available();success=true;}catch(Exception unavailable){/* Legacy/manual sharing remains available. */}finally{boolean result=success;main.post(()->{livePolling=false;liveFailures=result?0:Math.min(4,liveFailures+1);main.removeCallbacks(livePoll);if(active()&&allowed())main.postDelayed(livePoll,AutomaticSyncCadence.CLIPBOARD_DELAY_MS*(1L<<liveFailures));});}});}
 private final Runnable poll=this::runAutomaticPoll;
 private void runAutomaticPoll(){
  if(!imeSafe||foreground>0||!allowed()||polling)return;polling=true;
  SyncTasks.worker.execute(()->{boolean success=false;try{synchronizeActive(new SyncClient(context));success=true;}catch(Exception unavailable){/* Existing shared text and queued data remain available. */}finally{boolean succeeded=success;main.post(()->{polling=false;main.removeCallbacks(AutoClipboardBridge.this.poll);if(imeSafe&&foreground==0&&allowed())main.postDelayed(AutoClipboardBridge.this.poll,activePollDelay(succeeded));});}});
 }
 private boolean observe(boolean changed){
  if(!allowed()){state.reset("");return false;}if(!active()||clipboard==null)return false;
  KeyguardManager keyguard=(KeyguardManager)context.getSystemService(Context.KEYGUARD_SERVICE);if(keyguard!=null&&keyguard.isKeyguardLocked())return false;
  try{
   ClipDescription description=clipboard.getPrimaryClipDescription();
   if(description==null){
    // A null can also mean an access denial. Verify the existing default-IME
    // read capability instead of guessing that every null means empty.
    String selected=android.provider.Settings.Secure.getString(context.getContentResolver(),android.provider.Settings.Secure.DEFAULT_INPUT_METHOD);
    boolean defaultIme=selected!=null&&selected.startsWith(context.getPackageName()+"/");
    return AutoClipboardObservation.noDescription(state,changed?"cleared-or-unavailable:"+SystemClock.uptimeMillis():"known-empty",changed,true,defaultIme,clipboard.hasPrimaryClip());
   }
   String unavailableVersion="unsupported:"+description.getTimestamp();
   if(!description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)){state.observe(unavailableVersion,null,false);return true;}
   PersistableBundle extra=description.getExtras(); // Provider hints do not change authorized readable-text transport.
   ClipData data=clipboard.getPrimaryClip();if(data==null||data.getItemCount()!=1){state.observe(unavailableVersion,null,false);return true;}ClipData.Item item=data.getItemAt(0);
   if(item.getUri()!=null||item.getIntent()!=null||item.getText()==null){state.observe(unavailableVersion,null,false);return true;}String text=item.getText().toString();if(!AutoClipboardState.eligible(text)){state.observe(unavailableVersion,null,false);return true;}
   long timestamp=description.getTimestamp();if(timestamp<=0&&!changed)return false;
   String version=(timestamp>0?Long.toString(timestamp):"undated:"+(++undatedVersion))+":"+SyncCrypto.b64(SyncCrypto.sha(SyncCrypto.bytes(text)));
   state.observe(version,text,extra!=null&&origin.equals(extra.getString("live.linghe.clipboard.auto.origin","")));
   sendPending();return true;
  }catch(Exception denied){return false;/* No accessibility/background bypass. */}
 }
 private void sendPending(){
  if(sending||!active()||!allowed()||state.pending()==null)return;sending=true;
  liveWorker.execute(()->{
   AutoClipboardState.Copy copy=state.pending();boolean queued=false;
   try{ClipboardLiveStore storage=new ClipboardLiveStore(context);JSONObjectBox box=new JSONObjectBox(storage.snapshot());if(copy!=null&&box.credential!=null&&storage.authorized(box.credential)){String scope=box.credential.getString("scope");AutoClipboardState.Pass pass=state.begin(scope);if(state.current(pass)&&state.pending()==copy)queued=new ClipboardLiveClient(context).queue(copy.text,scope);if(queued)state.queued(copy);}}
   catch(Exception unavailable){/* Durable legacy fallback below retains original consent guards. */}
   if(queued){main.post(()->{sending=false;wakeLive();});return;}
   SyncTasks.worker.execute(()->{
    try{SyncClient client=new SyncClient(context);String scope=client.automaticClipboardScope();AutoClipboardState.Pass pass=state.begin(scope);AutoClipboardState.Copy pending=state.pending();if(pending!=null&&!scope.isEmpty()&&state.current(pass)){client.queueAutomaticText(pending.text,scope);state.queued(pending);synchronizeActive(client);}}
    catch(Exception unavailable){/* An unqueued current copy remains pending. */}
    finally{main.post(()->{sending=false;});}
   });
  });
 }
 private static final class JSONObjectBox{final org.json.JSONObject credential;JSONObjectBox(org.json.JSONObject s){credential=s.optJSONObject("credential");}}
 AutoClipboardState.Pass beginPass(String scope,boolean outgoing){return state.begin(scope,outgoing);}
 void completedPass(AutoClipboardState.Pass pass,List<Incoming> incoming,boolean drained,long consent,long automatic,String privacy){
  // Reserve even a discarded observation once. Main-thread safety/permission
  // failure must not cause a later retry to overwrite the user's clipboard.
  if(!allowed()||prefs.getLong("generation",0)!=consent||prefs.getLong(GENERATION,0)!=automatic||!privacy.equals(PersonalReset.generation(context)))return;
  ArrayList<Incoming> once=new ArrayList<>();
  for(Incoming item:incoming)if(!item.ownSender&&AutoClipboardState.eligible(item.text))try{if(ClipboardOnceReceipts.claim(context,ClipboardOnceReceipts.DELIVERY,item.text,privacy))once.add(item);}catch(Exception unavailable){/* Skip auto-delivery; explicit shared text is retained. */}
  main.post(()->{
   if(!allowed()||prefs.getLong("generation",0)!=consent||prefs.getLong(GENERATION,0)!=automatic||!privacy.equals(PersonalReset.generation(context))||!state.current(pass))return;
   // Re-read now: a clipboard listener may be delayed while the network waits.
   boolean safeNow=observe(false);Incoming newest=null;
   for(Incoming item:once)if(state.accept(pass,item.identity,item.expires<=System.currentTimeMillis()/1000,item.ownSender)&&active()&&safeNow)newest=item;
   if(drained)state.drained(pass);
   if(newest!=null&&clipboard!=null){
    ClipData data=ClipData.newPlainText("灵鹤共享文本",newest.text);markOwn(data,newest.event);data.getDescription().getExtras().putBoolean("live.linghe.clipboard.auto.incoming",true);ActivityArchiveManager.get(context).ownClipboard(data,newest.event);
    try{clipboard.setPrimaryClip(data);}catch(RuntimeException unavailable){/* Manual shared text remains readable. */}
   }
  });
 }
 void markOwn(ClipData clip,String event){PersistableBundle extras=clip.getDescription().getExtras();if(extras==null)extras=new PersistableBundle();extras.putString("live.linghe.clipboard.auto.origin",origin);clip.getDescription().setExtras(extras);}
}
