package live.linghe.privateinput;

import android.app.*;
import android.app.job.*;
import android.content.*;
import android.os.*;
import android.view.inputmethod.EditorInfo;
import java.io.*;
import java.net.*;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.*;
import javax.net.ssl.HttpsURLConnection;
import org.json.*;

/** Plaintext archive is opt-in, independent of encrypted sync. No work blocks input. */
final class ActivityArchiveManager {
  private static ActivityArchiveManager instance;
  static synchronized ActivityArchiveManager get(Context context){if(instance==null)instance=new ActivityArchiveManager(context.getApplicationContext());return instance;}
  private final Context context;private final SharedPreferences prefs;private final ActivityArchiveQueue queue;
  private final ExecutorService storage=Executors.newSingleThreadExecutor();
  private final ScheduledExecutorService network=Executors.newSingleThreadScheduledExecutor();
  private final Handler main=new Handler(Looper.getMainLooper());private final ClipboardManager clipboard;
  private volatile HttpsURLConnection activeConnection;private volatile String status="尚未开启";private volatile long pending,held;private final java.util.concurrent.atomic.AtomicInteger captureInFlight=new java.util.concurrent.atomic.AtomicInteger();
  private ScheduledFuture<?> scheduled;private int failures;private volatile int foreground;
  private volatile boolean imeSafe;private volatile String clipboardOriginToken="",clipboardOriginReference="";
  private final ClipboardManager.OnPrimaryClipChangedListener clipboardListener=()->observeClipboard(true);
  static final class Identity {
    final JSONObject identity,membership;final String group,device;
    Identity(JSONObject state)throws Exception{
      SyncCrypto.require(state.has("identity")&&state.has("membership")&&state.has("groupKey")&&!state.optBoolean("wipePending"));
      identity=state.getJSONObject("identity");membership=state.getJSONObject("membership");group=ActivityArchiveRules.id(membership.getString("group"));device=ActivityArchiveRules.id(identity.getString("device"));
      SyncCrypto.verifyMembership(membership,state.getJSONObject("anchor"),null);SyncCrypto.find(membership,device);
    }
  }
  interface Completion {void complete(String error);}
  private ActivityArchiveManager(Context context){
    this.context=context;prefs=context.getSharedPreferences("activity-archive",0);queue=new ActivityArchiveQueue(context);clipboard=(ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE);
    if(clipboard!=null)try{clipboard.addPrimaryClipChangedListener(clipboardListener);}catch(RuntimeException unavailable){status="系统未提供剪贴板观察能力";}
    storage.execute(()->{try{if(prefs.getBoolean("wipePending",false)||!privacyCurrent()){pauseForDeparture();return;}refreshCounts();}catch(Exception failure){status="本机归档队列暂不可用；输入不受影响";}});
    if(enabled())status=prefs.getBoolean("transportBlocked",false)?"归档已停记，暂存队列待核对":prefs.getBoolean("capturePaused",false)?"已暂停新增采集，等待服务器恢复":"等待上传";
    scheduleJob();if(enabled())schedule(1);else if(prefs.getBoolean("revokePending",false))network.execute(this::revokeRemote);
  }
  boolean enabled(){return prefs.getBoolean("enabled",false);}
  boolean inputEnabled(){return enabled()&&!prefs.getBoolean("capturePaused",false)&&prefs.getBoolean("input",false);}
  boolean diagnosticEnabled(){return enabled()&&!prefs.getBoolean("capturePaused",false)&&prefs.getBoolean("diagnostic",false);}
  boolean clipboardEnabled(){return enabled()&&!prefs.getBoolean("capturePaused",false)&&prefs.getBoolean("clipboard",false);}
  String endpoint(){return prefs.getString("endpoint","");}
  String health(){return status+"\n待上传 "+pending+" 条 · 旧授权暂存 "+held+" 条"+(prefs.getLong("gapCount",0)>0?" · 未归档 "+prefs.getLong("gapCount",0)+" 次":"");}
  private void refreshCounts(){long all=queue.pending();pending=enabled()&&!prefs.getBoolean("transportBlocked",false)?queue.pending(generation()):0;held=Math.max(0,all-pending);}
  boolean useRelay(){return prefs.getBoolean("useRelay",true);}
  boolean shareReaders(){return prefs.getBoolean("shareReaders",false);}
  private long generation(){return prefs.getLong("generation",0);}
  private boolean privacyCurrent(){String bound=prefs.getString("privacyGeneration",PersonalReset.generation(context));return !prefs.getBoolean("wipePending",false)&&bound.equals(PersonalReset.generation(context))&&!PersonalReset.expired(context)&&!context.getSharedPreferences("privacy-reset",0).getBoolean("pending",false);}
  private boolean active(long generation){return enabled()&&generation()==generation&&privacyCurrent();}
  void foreground(boolean on){foreground=Math.max(0,foreground+(on?1:-1));if(on){if(prefs.getBoolean("wipePending",false))storage.execute(this::pauseForDeparture);observeClipboard(false);if(enabled())flush();}}
  InputProvider inputProvider(){return new InputProvider();}
  final class InputProvider implements ActivityArchiveProvider {
    private String source,session,epoch;private boolean safe;private final InputDecisionEvidence.Scope diagnosticScope=new InputDecisionEvidence.Scope();private String fieldType,returnKey,layout;private final InputDecisionEvidence.Owner decisions=new InputDecisionEvidence.Owner();private final LinkedHashMap<String,InputDecisionEvidence> decisionSnapshots=new LinkedHashMap<>();private final Set<String> emittedSnapshots=new HashSet<>();private InputDecisionEvidence decisionPress,decisionRelease;
    public String[] capabilities(){return new String[]{"ime.commit.v1","ime.diagnostic.v1","app.paste.v1"};}
    public synchronized void start(String sourceApp,boolean safeField){diagnosticScope.advance();decisions.reset();decisionSnapshots.clear();emittedSnapshots.clear();decisionPress=decisionRelease=null;source=sourceApp;safe=safeField;fieldType=null;returnKey=null;layout=null;session=ActivityArchiveRules.id();epoch=ActivityArchiveRules.id();imeSafe=safeField;if(!safeField&&inputEnabled())status="安全或未知输入框已停记；输入不受影响";}
    void start(EditorInfo info){start(info==null?null:info.packageName,info!=null&&ActivityArchiveRules.safeInput(info.inputType,info.imeOptions,true));if(info!=null){fieldType="android_input_type_"+info.inputType;returnKey="ime_action_"+(info.imeOptions&EditorInfo.IME_MASK_ACTION);}}
    public synchronized void pause(){diagnosticScope.advance();decisions.reset();decisionSnapshots.clear();emittedSnapshots.clear();decisionPress=decisionRelease=null;safe=false;imeSafe=false;session=null;epoch=null;}
    synchronized void uncertainEdit(){diagnosticScope.advance();decisions.reset();decisionSnapshots.clear();emittedSnapshots.clear();decisionPress=decisionRelease=null;epoch=ActivityArchiveRules.id();}
    void layout(String value){layout=value;}
    synchronized long diagnosticsToken(){return safe&&diagnosticEnabled()?diagnosticScope.current():0;}
    synchronized void diagnostic(long expected,String key,String before,String after){
      if(expected==0||!diagnosticScope.accepts(expected)||!safe||!diagnosticEnabled()||key==null||before==null||after==null||key.length()>128||before.length()>2048||after.length()>2048)return;
      try{JSONObject detail=new JSONObject().put("action",key.equals("backspace")?"delete":key.startsWith("literal:")?"literal":key.equals("edit")?"edit":"key").put("key",key).put("raw_before",before).put("raw_after",after).put("committed",false);
        emit("ime.diagnostic.v1","source_import",after,"ime_diagnostic",source,session,epoch,"not_applicable",null,null,fieldType,returnKey,layout,detail);
      }catch(Exception ignored){}
    }
    synchronized boolean diagnosticCurrent(long expected){return expected!=0&&diagnosticScope.accepts(expected)&&safe&&diagnosticEnabled();}
    synchronized InputDecisionEvidence snapshot(long expected,String raw,String[][] rows){if(!diagnosticCurrent(expected))return null;InputDecisionEvidence value=decisions.snapshot(raw,rows,SystemClock.elapsedRealtimeNanos()/1000);decisionSnapshots.put(value.state,value);while(decisionSnapshots.size()>8)decisionSnapshots.remove(decisionSnapshots.keySet().iterator().next());return value;}
    synchronized void marked(long expected,InputDecisionEvidence value,String text,String status){if(!diagnosticCurrent(expected)||value==null)return;InputDecisionEvidence prior=decisionSnapshots.get(value.state);if(prior!=null)decisionSnapshots.put(value.state,prior.marked(text,status));}
    synchronized void decision(long expected,InputDecisionEvidence value){
      if(!diagnosticCurrent(expected)||value==null)return;
      if(value.stage.equals("input")||value.stage.equals("candidates"))return;
      if(value.stage.equals("press")){decisionPress=value;decisionRelease=null;return;}
      if(value.stage.equals("release")){decisionRelease=value;return;}
      InputDecisionEvidence summary="touch".equals(value.method)?value.touch(decisionPress,decisionRelease):value;InputDecisionEvidence snapshot=decisionSnapshots.get(value.state);if(snapshot!=null&&snapshot.markedStatus!=null)summary=summary.marked(snapshot.markedText,snapshot.markedStatus);
      if(snapshot!=null&&emittedSnapshots.add(snapshot.state))emitDecision(expected,snapshot.model(value.modelVersion,value.localOverlay));
      emitDecision(expected,summary);if(emittedSnapshots.size()>32)emittedSnapshots.clear();
      if(value.stage.equals("commit")||value.stage.equals("cancel")){decisionPress=decisionRelease=null;}
    }
    private void emitDecision(long expected,InputDecisionEvidence value){InputDecisionEvidence.Scope.Frozen captured=diagnosticScope.freeze(expected,safe,diagnosticEnabled(),session,epoch);if(captured==null)return;emit("ime.diagnostic.v1","source_import",value.raw,"ime_diagnostic",source,captured.session,captured.epoch,"not_applicable",null,null,fieldType,returnKey,layout,null,value,null,this,expected);}
    synchronized void compositionEnded(long expected){if(diagnosticCurrent(expected))decisions.reset();}
    synchronized void committedDecision(long expected,String text,boolean acknowledged,InputDecisionEvidence value){
      InputDecisionEvidence.CommitPermission allowed=new InputDecisionEvidence.CommitPermission(safe,inputEnabled(),diagnosticEnabled(),diagnosticScope.accepts(expected),value!=null);String output=allowed.output?ActivityArchiveRules.id():null;
      if(allowed.output)emit("ime.commit.v1","input_commit",text,"ime",source,session,epoch,acknowledged?"editor_acknowledged":"insert_requested",null,null,fieldType,returnKey,layout,null,null,allowed.link?value:null,null,0,output);
      if(allowed.diagnostic)decision(expected,value.event("commit",value.selected,value.method,value.reason,output,SystemClock.elapsedRealtimeNanos()/1000));
    }
    public void committed(String text,boolean acknowledged){if(safe&&inputEnabled())emit("ime.commit.v1","input_commit",text,"ime",source,session,epoch,acknowledged?"editor_acknowledged":"insert_requested",null,null,fieldType,returnKey,layout);}
    void systemClipboardCommitted(String text,boolean acknowledged){if(safe&&clipboardEnabled()&&pasteAllowed())emit("app.paste.v1","paste_action",text,"system_clipboard",source,session,epoch,acknowledged?"editor_acknowledged":"insert_requested","system_clipboard",null,fieldType,returnKey,layout);}
    void revised(String text){if(safe&&inputEnabled()){uncertainEdit();emit("ime.commit.v1","text_revise",text,"ime",source,session,epoch,"editor_acknowledged",null,null,fieldType,returnKey,layout);}}
    public void flush(){ActivityArchiveManager.this.flush();}
    public String health(){return ActivityArchiveManager.this.health();}
  }
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference){
    emit(provider,type,text,sourceKind,source,session,epoch,confirmation,origin,reference,null,null,null);
  }
  private void emitClipboard(String text,String origin,String reference,boolean providerDeclaredSensitive){
    emit("clipboard.observed.v1","clipboard_observed",text,"clipboard",null,null,null,"observed_match",origin,reference,null,null,null,null,null,null,null,0,ActivityArchiveRules.id(),providerDeclaredSensitive?"provider_declared_sensitive":"personal");
  }
  private JSONObject sourceContext(String source,String fieldType,String returnKey,String layout)throws Exception{
    String version=null,build=null,name=null;
    try{android.content.pm.PackageInfo own=context.getPackageManager().getPackageInfo(context.getPackageName(),0);version=own.versionName;build=String.valueOf(Build.VERSION.SDK_INT>=28?own.getLongVersionCode():own.versionCode);}catch(Exception unavailable){}
    // Resolve the immutable captured package, never whichever app is now frontmost.
    if(source!=null)try{name=context.getPackageManager().getApplicationLabel(context.getPackageManager().getApplicationInfo(source,0)).toString();}catch(Exception unavailable){}
    return new JSONObject(ActivitySourceContext.fields("android",source,name,version,build,fieldType,returnKey,layout,source==null?"archive_provider":"default_ime"));
  }
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference,String fieldType,String returnKey,String layout){
    emit(provider,type,text,sourceKind,source,session,epoch,confirmation,origin,reference,fieldType,returnKey,layout,null);
  }
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference,String fieldType,String returnKey,String layout,JSONObject diagnostic){
    emit(provider,type,text,sourceKind,source,session,epoch,confirmation,origin,reference,fieldType,returnKey,layout,diagnostic,null,null,null,0);
  }
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference,String fieldType,String returnKey,String layout,JSONObject diagnostic,InputDecisionEvidence decision,InputDecisionEvidence link,InputProvider guard,long expected){emit(provider,type,text,sourceKind,source,session,epoch,confirmation,origin,reference,fieldType,returnKey,layout,diagnostic,decision,link,guard,expected,ActivityArchiveRules.id());}
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference,String fieldType,String returnKey,String layout,JSONObject diagnostic,InputDecisionEvidence decision,InputDecisionEvidence link,InputProvider guard,long expected,String event){
    emit(provider,type,text,sourceKind,source,session,epoch,confirmation,origin,reference,fieldType,returnKey,layout,diagnostic,decision,link,guard,expected,event,"personal");
  }
  private void emit(String provider,String type,String text,String sourceKind,String source,String session,String epoch,String confirmation,String origin,String reference,String fieldType,String returnKey,String layout,JSONObject diagnostic,InputDecisionEvidence decision,InputDecisionEvidence link,InputProvider guard,long expected,String event,String sensitivity){
    if(!enabled()||!privacyCurrent())return;
    if(!type.equals("coverage_gap")&&!((diagnostic!=null||decision!=null)&&text!=null&&text.isEmpty())&&!ActivityArchiveRules.acceptedText(text)){gap("正文过大或Unicode无效");return;}
    if(captureInFlight.incrementAndGet()>64){captureInFlight.decrementAndGet();gap("归档写入暂时繁忙，存在覆盖缺口");return;}
    final long token=generation(),observed=System.currentTimeMillis();
    storage.execute(()->{
      try{
        if(!active(token)||decision!=null&&!diagnosticEnabled())return;
        String group=prefs.getString("group",""),device=prefs.getString("device","");
        if(group.isEmpty()||device.isEmpty()){pauseForRevocation();return;}
        SimpleDateFormat date=new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",Locale.ROOT);date.setTimeZone(TimeZone.getTimeZone("UTC"));
        JSONObject row=new JSONObject().put("schema_version",1).put("event_id",event).put("device_group",group).put("device_id",device)
          .put("provider_id",provider).put("event_type",type).put("observed_at",date.format(new Date(observed))).put("timezone_id",TimeZone.getDefault().getID())
          .put("utc_offset_minutes",TimeZone.getDefault().getOffset(observed)/60000).put("content",new JSONObject().put("text",text))
          .put("source_kind",sourceKind).put("source_app",source==null?JSONObject.NULL:source).put("input_session",session==null?JSONObject.NULL:session)
          .put("editor_epoch",epoch==null?JSONObject.NULL:epoch).put("span_id",event).put("edit_op",new JSONObject().put("kind","unknown").put("anchor",JSONObject.NULL))
          .put("document_id",JSONObject.NULL).put("delivery_state","draft_unknown").put("commit_confirmation",confirmation).put("consent_version",prefs.getLong("consentVersion",0))
          .put("sensitivity",sensitivity).put("time_quality","device_clock_unverified").put("links",new JSONArray());
        JSONObject extensions=new JSONObject().put(ActivitySourceContext.KEY,sourceContext(source,fieldType,returnKey,layout));
        extensions.put("org.linghe.device.v1",new JSONObject().put("platform","android").put("device_type","mobile_device").put("brand",Build.BRAND).put("manufacturer",Build.MANUFACTURER).put("model",Build.MODEL).put("os_version",Build.VERSION.RELEASE));
        if(diagnostic!=null)extensions.put("org.linghe.input.v1",diagnostic);
        if(decision!=null)extensions.put(InputDecisionEvidence.KEY,decisionJSON(decision));
        if(link!=null)extensions.put(InputDecisionEvidence.LINK,new JSONObject().put("composition_id",link.composition).put("decision_id",link.decision).put("state_id",link.state));
        if(origin!=null){JSONObject extra=new JSONObject().put("origin",origin);if(reference!=null&&!reference.isEmpty())extra.put("origin_event_reference",reference);extensions.put("org.linghe.provenance.v1",extra);}
        row.put("extensions",extensions);
        if(!active(token))return;
        if(!queue.enqueue(row,token)){gap("本机队列已满或单条超限，部分内容未归档");return;}
        reportPendingGap(row,token);refreshCounts();status="等待上传";schedule(1);
      }catch(Exception failure){gap("写入归档队列失败；输入不受影响");}
      finally{captureInFlight.decrementAndGet();}
    });
  }
  private static JSONObject candidateJSON(InputDecisionEvidence.Candidate value)throws Exception{return new JSONObject().put("candidate_id",value.id).put("text",value.text).put("reading",value.reading).put("absolute_rank",value.rank).put("source",value.source);}
  static JSONObject decisionJSON(InputDecisionEvidence value)throws Exception{
    JSONObject out=new JSONObject().put("version",1).put("composition_id",value.composition).put("revision",value.revision).put("state_id",value.state).put("decision_id",value.decision).put("snapshot_id",value.snapshot).put("stage",value.stage).put("clock_domain",InputDecisionEvidence.CLOCK).put("monotonic_us",value.micros).put("core_hash",SyncBuildConfig.CORE_HASH).put("resource_hash",SyncBuildConfig.RESOURCE_HASH).put("policy_hash",SyncBuildConfig.POLICY_HASH);
    if(value.stage.equals("candidates")){JSONArray rows=new JSONArray();for(InputDecisionEvidence.Candidate item:value.candidates)rows.put(candidateJSON(item));out.put("candidates",rows).put("observed_count",rows.length()).put("coverage","published_subset").put("truncated",value.truncated);}
    if(value.markedStatus!=null)out.put("marked_text",value.markedText).put("marked_status",value.markedStatus);
    if(value.pressState!=null)out.put("press_state_id",value.pressState);if(value.releaseState!=null)out.put("release_state_id",value.releaseState);if(value.pressMicros>=0)out.put("press_monotonic_us",value.pressMicros);if(value.releaseMicros>=0)out.put("release_monotonic_us",value.releaseMicros);
    if(value.selected!=null){if(!value.selected.textTruncated)out.put("selected_candidate",candidateJSON(value.selected));out.put("selected_candidate_id",value.selected.id).put("selected_rank",value.selected.rank);if(value.selected.textTruncated)out.put("reason",value.reason==null?"selected_text_too_large":value.reason+"_selected_text_too_large");}
    if(value.modelVersion!=null&&value.modelVersion.matches("[A-Za-z0-9_.:-]{1,96}"))out.put("model_version",value.modelVersion);if(value.localOverlay!=null)out.put("local_overlay",value.localOverlay);
    if(value.method!=null)out.put("method",value.method);if(value.reason!=null&&!out.has("reason"))out.put("reason",value.reason);if(value.output!=null)out.put("output_event_id",value.output);return out;
  }
  private void gap(String reason){synchronized(prefs){prefs.edit().putLong("gapCount",prefs.getLong("gapCount",0)+1).putLong("pendingGapCount",prefs.getLong("pendingGapCount",0)+1).apply();}status=reason;}
  private void reportPendingGap(JSONObject template,long token)throws Exception {
    synchronized(prefs){long count=prefs.getLong("pendingGapCount",0);if(count<=0||!active(token))return;
      JSONObject event=new JSONObject(template.toString()).put("event_id",ActivityArchiveRules.id()).put("event_type","coverage_gap").put("content",new JSONObject().put("text","")).put("input_session",JSONObject.NULL).put("editor_epoch",JSONObject.NULL)
        .put("extensions",new JSONObject().put("org.linghe.coverage.v1",new JSONObject().put("unrecorded_events",count).put("reason","local_capture_or_queue_limit")));
      event.put("source_app",JSONObject.NULL).getJSONObject("extensions").put(ActivitySourceContext.KEY,sourceContext(null,null,null,null));
      if(queue.enqueue(event,token))prefs.edit().putLong("pendingGapCount",0).apply();
    }
  }
  void ownClipboard(ClipData data,String reference){
    clipboardOriginToken=ActivityArchiveRules.id();clipboardOriginReference=reference==null?"":reference;PersistableBundle extras=data.getDescription().getExtras();if(extras==null)extras=new PersistableBundle();extras.putString("live.linghe.archive.origin",clipboardOriginToken);data.getDescription().setExtras(extras);
  }
  private void observeClipboard(boolean changed){
    if(!clipboardEnabled()||!privacyCurrent()||clipboard==null)return;
    KeyguardManager lock=(KeyguardManager)context.getSystemService(Context.KEYGUARD_SERVICE);
    if(lock!=null&&lock.isKeyguardLocked()){status="锁屏期间剪贴板不可读";return;}
    if(foreground==0&&!imeSafe){status="剪贴板只在应用前台或安全键盘会话中观察";return;}
    try{
      android.content.ClipDescription description=clipboard.getPrimaryClipDescription();PersistableBundle declared=description==null?null:description.getExtras();
      ClipData data=clipboard.getPrimaryClip();if(data==null||data.getItemCount()==0)return;
      PersistableBundle extras=data.getDescription().getExtras();boolean providerDeclaredSensitive=(declared!=null&&declared.getBoolean("android.content.extra.IS_SENSITIVE",false))||(extras!=null&&extras.getBoolean("android.content.extra.IS_SENSITIVE",false));
      long timestamp=data.getDescription().getTimestamp();String key=Long.toString(timestamp)+":"+data.getItemCount();
      if(!changed&&timestamp>0&&key.equals(prefs.getString("clipboardVersion","")))return;
      if(timestamp<=0&&!changed)return; // cannot prove a new observed version on foreground re-entry.
      String origin=extras!=null&&clipboardOriginToken.equals(extras.getString("live.linghe.archive.origin",""))&&!clipboardOriginToken.isEmpty()?"sync_received":"unknown";
      for(int i=0;i<data.getItemCount();i++){CharSequence text=data.getItemAt(i).getText();if(text!=null&&!text.toString().isEmpty())emitClipboard(text.toString(),origin,origin.equals("sync_received")?clipboardOriginReference:null,providerDeclaredSensitive);}
      if(timestamp>0)prefs.edit().putString("clipboardVersion",key).apply();
    }catch(SecurityException blocked){status="系统未允许读取当前剪贴板";}catch(RuntimeException failure){status="当前剪贴板无法读取；输入不受影响";}
  }
  boolean pasteAllowed(){
    if(!clipboardEnabled()||!privacyCurrent())return false;
    try{if(clipboard!=null)clipboard.getPrimaryClipDescription();return true;}catch(RuntimeException unavailable){return false;}
  }
  void explicitPaste(String text,boolean safeField){if(safeField&&pasteAllowed())emit("app.paste.v1","paste_action",text,"app_paste",context.getPackageName(),ActivityArchiveRules.id(),ActivityArchiveRules.id(),"editor_acknowledged",null,null);}
  void retry(){if(enabled()){prefs.edit().putBoolean("transportBlocked",false).apply();schedule(0);}}
  void flush(){if(enabled())schedule(0);else if(prefs.getBoolean("revokePending",false))network.execute(this::revokeRemote);}
  void flush(Completion completion){network.execute(()->{if(enabled())upload();else revokeRemote();completion.complete(null);});}
  private synchronized void schedule(long seconds){if(!enabled()||prefs.getBoolean("transportBlocked",false))return;if(scheduled!=null&&!scheduled.isDone())return;scheduled=network.schedule(()->{synchronized(ActivityArchiveManager.this){scheduled=null;}upload();},seconds,TimeUnit.SECONDS);}
  private void upload(){
    final long token=generation();if(!active(token)||prefs.getBoolean("transportBlocked",false))return;
    try{
      Identity identity=new Identity(new SyncStore(context).load());
      if(!identity.group.equals(prefs.getString("group",""))||!identity.device.equals(prefs.getString("device",""))){pauseForRevocation();return;}
      JSONObject remote=request(identity,endpoint(),1,new JSONObject(),token,true);JSONObject consent=remote.optJSONObject("consent");
      if(!remote.optBoolean("enabled")||consent==null||!consent.optBoolean("enabled")||consent.optLong("version")!=prefs.getLong("consentVersion",0)){pauseForRevocation();return;}
      for(int count=0;count<4&&active(token);count++){
        JSONArray rows=queue.batch(token);if(rows.length()==0){pending=0;if(prefs.getBoolean("capturePaused",false)){prefs.edit().putBoolean("capturePaused",false).apply();gap("归档暂停期间存在覆盖缺口");}status="归档已更新";failures=0;return;}
        ArrayList<String> ids=new ArrayList<>();for(int n=0;n<rows.length();n++)ids.add(rows.getJSONObject(n).getString("event_id"));String batchID=ActivityArchiveRules.batchID(ids);JSONObject result=request(identity,endpoint(),4,new JSONObject().put("batch_id",batchID).put("events",rows),token,true);
        SyncCrypto.require(batchID.equals(ActivityArchiveRules.id(result.getString("batch_id"))));
        queue.acknowledge(rows,result);refreshCounts();status="归档已更新";
      }
      failures=0;if(pending>0)schedule(1);
    }catch(Exception error){
      if(!active(token))return;
      if(error instanceof ArchiveFailure){
        String code=((ArchiveFailure)error).code;
        if(code.equals("member_inactive")||code.equals("member_removed")||code.equals("not_member")||code.equals("device_departed")){pauseForRevocation();status="设备组身份待核对，已停记并暂存旧队列";SyncTasks.worker.execute(()->{try{new SyncClient(context).synchronize();}catch(Exception unavailable){}});return;}
        if(java.util.Arrays.asList("group","membership_anchor","membership_invalid","membership_profile","signature","consent_required","consent_disabled","consent_stale","archive_disabled","provider_not_allowed","event_identity").contains(code)){pauseForRevocation();return;}
        if(java.util.Arrays.asList("event_expired","event_erased","event_conflict","sequence_conflict","batch_conflict","event_clock","request_clock").contains(code)){
          prefs.edit().putBoolean("capturePaused",true).putBoolean("transportBlocked",true).commit();
          status="归档已停记："+code+"；待发仍保留，可核对后重试或清待发重开";return;
        }
        if(code.equals("group_capacity")||code.equals("archive_capacity")){
          prefs.edit().putBoolean("capturePaused",true).commit();status="归档服务器容量不足，已暂停新增采集；待发仍保留";failures=Math.min(8,failures+1);schedule(300);return;
        }
      }
      status="上传暂时失败，本机待发内容已保留";failures=Math.min(8,failures+1);schedule(Math.min(300,1L<<failures)+new Random().nextInt(3));
    }
  }
  void configure(String supplied,boolean relay,boolean input,boolean clips,boolean readers,Completion completion){
    configure(supplied,relay,input,clips,false,readers,completion);
  }
  void configure(String supplied,boolean relay,boolean input,boolean clips,boolean diagnostic,boolean readers,Completion completion){
    if(!input&&!clips&&!diagnostic){pause();main.post(()->completion.complete(null));return;}
    pause();final long token=generation();
    network.execute(()->{String error=null;try{
      if(!privacyCurrent())throw new IOException("本机归档清理尚未完成，请稍后重试");
      Identity identity=new Identity(new SyncStore(context).load());JSONObject state=new SyncStore(context).load();
      String address=SyncClient.endpoint(relay?state.getString("endpoint"):supplied);
      JSONObject remote=request(identity,address,1,new JSONObject(),token,false);
      if(!remote.optBoolean("enabled"))throw new IOException("设备组尚未开启归档，请先明确开启组归档");
      JSONObject old=remote.optJSONObject("consent");JSONArray providers=new JSONArray();if(diagnostic)providers.put("ime.diagnostic.v1");if(input)providers.put("ime.commit.v1");if(clips){providers.put("clipboard.observed.v1");providers.put("app.paste.v1");}
      JSONArray scopes=new JSONArray();if(readers){JSONArray members=identity.membership.getJSONArray("members");for(int i=0;i<members.length();i++)scopes.put(ActivityArchiveRules.id(members.getJSONObject(i).getString("device")));}else scopes.put(identity.device);
      JSONObject result=request(identity,address,3,new JSONObject().put("expected_version",old==null?0:old.getLong("version")).put("enabled",true).put("providers",providers).put("readers",scopes),token,false);
      if(generation()!=token||!privacyCurrent())throw new IOException("归档设置已改变，请重新开启");
      synchronized(prefs){if(generation()!=token)throw new IOException("归档设置已改变");prefs.edit().putString("endpoint",address).putBoolean("useRelay",relay).putBoolean("input",input).putBoolean("clipboard",clips).putBoolean("diagnostic",diagnostic).putBoolean("shareReaders",readers).putString("group",identity.group).putString("device",identity.device).putString("privacyGeneration",PersonalReset.generation(context)).putLong("consentVersion",result.getLong("consent_version")).putBoolean("revokePending",false).putBoolean("capturePaused",false).putBoolean("transportBlocked",false).putBoolean("enabled",true).commit();}
      status="已开启，等待新的输出";scheduleJob();schedule(0);
    }catch(Exception failure){error=failure.getMessage();if(error==null)error="归档配置失败";status="未开启归档";}
      final String result=error;main.post(()->completion.complete(result));
    });
  }
  void groupPolicy(String supplied,boolean relay,boolean on,Completion completion){
    final long token=generation();network.execute(()->{String error=null;try{
      JSONObject state=new SyncStore(context).load();Identity identity=new Identity(state);String address=SyncClient.endpoint(relay?state.getString("endpoint"):supplied);
      JSONObject remote=request(identity,address,1,new JSONObject(),token,false),limits=remote.getJSONObject("limits");
      request(identity,address,2,new JSONObject().put("expected_version",remote.getLong("policy_version")).put("enabled",on).put("retention_days",limits.optInt("retention_days",30)).put("max_group_bytes",limits.optLong("max_group_bytes",104857600)),token,false);
      if(!on)pause();status=on?"组归档已开启；本机仍需单独同意":"组归档已关闭";
    }catch(Exception failure){error=failure.getMessage();if(error==null)error="组归档设置失败";}final String result=error;main.post(()->completion.complete(result));});
  }
  void pause(){pause(true);}
  private void pause(boolean revoke){
    synchronized(prefs){prefs.edit().putBoolean("capturePaused",false).putBoolean("transportBlocked",false).putBoolean("revokePending",revoke&&!prefs.getString("group","").isEmpty()).putBoolean("enabled",false).putBoolean("input",false).putBoolean("clipboard",false).putLong("generation",generation()+1).commit();}
    HttpsURLConnection current=activeConnection;if(current!=null)current.disconnect();
    synchronized(this){if(scheduled!=null){scheduled.cancel(false);scheduled=null;}}
    status="已暂停；旧授权记录本机暂存，不自动补传";
    storage.execute(()->{try{refreshCounts();}catch(Exception failure){status="已暂停，本机队列状态暂不可读";}});scheduleJob();if(revoke)network.execute(this::revokeRemote);
  }
  private void pauseForRevocation(){pause(false);status="服务器已关闭或更改授权；本机停记，旧队列已暂存";}
  void clearLocal(){pause();storage.execute(()->{try{queue.clearPending();pending=0;held=0;status="本机待发与暂存已清除；服务器已有记录仍保留";}catch(Exception failure){status="已暂停，本机清理待重试";}});}
  void pauseForDeparture(){pause(false);prefs.edit().putBoolean("wipePending",true).remove("group").remove("device").remove("consentVersion").putLong("gapCount",0).putLong("pendingGapCount",0).remove("clipboardVersion").putString("privacyGeneration",PersonalReset.generation(context)).commit();storage.execute(()->{try{queue.clearForDeparture();pending=0;held=0;prefs.edit().putBoolean("wipePending",false).commit();}catch(Exception failure){status="已离组，归档队列清理待重试";}});}
  private void revokeRemote(){
    if(enabled()||!prefs.getBoolean("revokePending",false))return;
    long token=generation();try{
      Identity identity=new Identity(new SyncStore(context).load());
      if(!identity.group.equals(prefs.getString("group",""))||!identity.device.equals(prefs.getString("device","")))return;
      JSONObject remote=request(identity,endpoint(),1,new JSONObject(),token,false),old=remote.optJSONObject("consent");
      if(old!=null&&old.optBoolean("enabled"))request(identity,endpoint(),3,new JSONObject().put("expected_version",old.getLong("version")).put("enabled",false).put("providers",old.getJSONArray("providers")).put("readers",old.getJSONArray("readers")),token,false);
      if(generation()==token){prefs.edit().putBoolean("revokePending",false).commit();scheduleJob();}
    }catch(Exception unavailable){if(generation()==token&&!enabled())status="已暂停；服务器停记通知待联网重试";}
  }
  private void scheduleJob(){JobScheduler jobs=context.getSystemService(JobScheduler.class);if(jobs==null)return;if(!enabled()&&!prefs.getBoolean("revokePending",false)){jobs.cancel(17002);return;}jobs.schedule(new JobInfo.Builder(17002,new ComponentName(context,ActivityArchiveJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(15*60*1000L).build());}
  static final class ArchiveFailure extends IOException {final String code;ArchiveFailure(int status,String code){super("归档服务器返回 "+status+"（"+code+"）");this.code=code;}}
  private JSONObject request(Identity identity,String endpoint,int operation,JSONObject body,long token,boolean requireEnabled)throws Exception {
    if(generation()!=token||requireEnabled&&!active(token))throw new IOException("归档操作已取消");
    HttpsURLConnection connection=(HttpsURLConnection)new URL(SyncClient.endpoint(endpoint)+"/v1/activity/rpc").openConnection();activeConnection=connection;
    connection.setInstanceFollowRedirects(false);connection.setConnectTimeout(10000);connection.setReadTimeout(15000);connection.setUseCaches(false);connection.setRequestMethod("POST");connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("Accept","application/json");
    byte[] payload=ActivityArchiveRules.bytes(ActivityArchiveWire.envelope(identity.identity,identity.group,operation,body,System.currentTimeMillis()/1000).toString());connection.setDoOutput(true);connection.setFixedLengthStreamingMode(payload.length);
    try{
      if(generation()!=token||requireEnabled&&!active(token))throw new IOException("归档操作已取消");
      try(OutputStream out=connection.getOutputStream()){if(generation()!=token||requireEnabled&&!active(token))throw new IOException("归档操作已取消");out.write(payload);}
      int code=connection.getResponseCode();InputStream stream=code==200?connection.getInputStream():connection.getErrorStream();ByteArrayOutputStream bytes=new ByteArrayOutputStream();
      if(stream!=null)try(InputStream in=stream){byte[] buffer=new byte[8192];int count;while((count=in.read(buffer))!=-1){if(bytes.size()+count>1048576)throw new IOException("归档响应超限");bytes.write(buffer,0,count);}}
      JSONObject result=LosslessJson.object(SyncCrypto.utf8(bytes.toByteArray()),1048576);
      if(code!=200){String reason=result.optString("error","request_failed");if(!reason.matches("[a-z_]{1,64}"))reason="request_failed";throw new ArchiveFailure(code,reason);}
      SyncCrypto.require(result.getInt("version")==1&&result.getInt("operation")==operation);return result.getJSONObject("result");
    }finally{connection.disconnect();if(activeConnection==connection)activeConnection=null;}
  }
}
