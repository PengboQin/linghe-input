package live.linghe.privateinput;
import android.inputmethodservice.InputMethodService;import android.view.*;import android.view.inputmethod.*;import android.widget.*;import android.os.*;import android.content.*;import android.graphics.Color;import android.graphics.drawable.GradientDrawable;import android.text.InputType;import java.io.*;import java.util.*;import java.util.concurrent.*;

public class LingheInputService extends InputMethodService {
 private ActivityArchiveManager.InputProvider activityArchive;
 private final ExecutorService worker=Executors.newSingleThreadExecutor(),recentIO=Executors.newSingleThreadExecutor();private final Handler main=new Handler(Looper.getMainLooper());
 private long session=0,version=0,dismissedContinuationEpoch=-1;private volatile int document=0;private boolean ready=false,english=false,nine=true,numbers=false,symbols=false,expanded=false,secure=false,privateInput=false,shift=false;
 private String builtLayout="",railSignature="",symbolRailContext="";private String[] symbolRailSnapshot={};private LinearLayout railStack;private TextView preeditText;
 private final ArrayList<Button> compositionClearKeys=new ArrayList<>();private boolean auxiliaryCandidatesShown;private int stableNavigationBottom=0;private int keyHeight=58;private Symbols catalog;private int symbolCategory=0;private boolean marked=false;private LinearLayout root,body,header;private String[][] snapshot={{"","","",""}};private String[] syllables={};private long visibleVersion=0;
 private final String[] punctuation={"，","。","！","？","、","：","；","“","”","（","）","…","—","·"};
 private final String[] numericPunctuation={".","@","-","+","/","%","=",":","(",")","$","¥"};
 private Runnable repeating;private int selectionStart=-1,selectionEnd=-1,cursorDocument=-1;private boolean cursorComposition=false;
 private InputQuality quality;private CommonExpressionOrder commonOrder;private final java.util.concurrent.atomic.AtomicLong inputEpoch=new java.util.concurrent.atomic.AtomicLong();
 private String deletionEditorPackage="";private int deletionEditorField=-1;
 private volatile boolean browsing=false;private final PredictionSuppression predictions=new PredictionSuppression();private Runnable qualityRefresh;private volatile ContextWindow context=ContextWindow.EMPTY;
 private final Map<String,InputQuality.Repair> repairPlans=new HashMap<>();private String[][] nativeSnapshot={{"","","","",""}};
 private EnglishSuggestions mixedEnglish;private PersonalLexicon personalStore;private PersonalLexicon.Snapshot personal;
 private final ArrayList<CandidateViews.Item> candidateItems=new ArrayList<>();
 private final ClipboardCandidateState clipboardSuggestions=new ClipboardCandidateState();
 private ClipboardManager clipboardCandidates;private boolean clipboardInputVisible;private ClipboardCandidateState.Value shownClipboardCandidate;
 private final ClipboardRefreshPolicy clipboardRefresh=new ClipboardRefreshPolicy();
 private final Runnable clipboardListenerRefresh=()->refreshClipboardCandidate(true);
 private final ClipboardManager.OnPrimaryClipChangedListener clipboardCandidateListener=()->{main.removeCallbacks(clipboardListenerRefresh);main.postDelayed(clipboardListenerRefresh,50);};
 private final Runnable clipboardHeartbeat=new Runnable(){public void run(){if(!clipboardInputVisible||destroyed)return;refreshClipboardCandidate(false);main.postDelayed(this,1000);}};
 private void startClipboardHeartbeat(){main.removeCallbacks(clipboardHeartbeat);if(clipboardInputVisible)main.postDelayed(clipboardHeartbeat,1000);}
 private void stopClipboardHeartbeat(){main.removeCallbacks(clipboardHeartbeat);main.removeCallbacks(clipboardListenerRefresh);clipboardRefresh.reset();}
 private void refreshClipboardCandidate(){refreshClipboardCandidate(true);}
 private long clipboardOfferGeneration;private String clipboardOfferPending="";
 private void publishClipboardCandidate(ClipboardCandidateState.Value value){boolean changed=clipboardSuggestions.offer(document,value);if(changed&&root!=null&&clipboardInputVisible&&!pending()&&(!english||EnglishCompletion.prefix(getCurrentInputConnection()).isEmpty()))render();}
 private void refreshClipboardCandidate(boolean listener){
  if(!clipboardRefresh.changed(ClipboardCandidateReader.metadata(this,getCurrentInputEditorInfo(),clipboardInputVisible),listener))return;
  ClipboardCandidateState.Value value=ClipboardCandidateReader.read(this,getCurrentInputEditorInfo(),clipboardInputVisible);
  if(value!=null){
   if(clipboardSuggestions.matches(document,value.id)||clipboardOfferPending.equals(value.id))return;
   long ticket=++clipboardOfferGeneration,epoch=inputEpoch.get();int target=document;String privacy=PersonalReset.generation(this);clipboardOfferPending=value.id;
   // Disk receipt work never runs on the key or UI executor. Reserve once even
   // when a later edit/document change makes this presentation unusable.
   recentIO.execute(()->{boolean first=false;try{first=ClipboardOnceReceipts.claim(this,ClipboardOnceReceipts.CANDIDATE,value.raw,privacy);}catch(Exception unavailable){}boolean accepted=first;main.post(()->{if(ticket!=clipboardOfferGeneration)return;clipboardOfferPending="";if(target!=document||epoch!=inputEpoch.get()||!clipboardInputVisible||pending()||symbols||secure||english&&!EnglishCompletion.prefix(getCurrentInputConnection()).isEmpty()||predictions.suppressed()||!privacy.equals(PersonalReset.generation(this)))return;publishClipboardCandidate(accepted?value:null);});});return;
  }
  ++clipboardOfferGeneration;clipboardOfferPending="";publishClipboardCandidate(value);
 }
 private void resumeSuggestionsForExplicitEdit(){if(shownClipboardCandidate!=null)clipboardSuggestions.consume(document,shownClipboardCandidate.id);predictions.explicitInput();dismissedContinuationEpoch=-1;inputEpoch.incrementAndGet();}

 private final LearningMaintenanceState maintenance=new LearningMaintenanceState();
 private final KeyboardRenderGate renderGate=new KeyboardRenderGate();
 private final java.util.concurrent.atomic.AtomicInteger queuedInputActions=new java.util.concurrent.atomic.AtomicInteger();
 private final CoalescedWork metadataRefresh=new CoalescedWork(recentIO,this::readMetadata);
 private final CoalescedWork recentRefresh=new CoalescedWork(recentIO,this::readRecentBatch);
 private final Object recentStageLock=new Object();private final ArrayList<RecentLearningStore.Selection> recentStaged=new ArrayList<>();private String recentStagedEpoch="",recentStagedLegacy;private long recentStagedRevision;
 private CandidateViews.Strip candidateStrip;private CandidateViews.Expanded candidateGrid;
 private int nativeLoaded=0;private boolean moreCandidates=false,loadingMore=false;

 private boolean personalReceiverRegistered=false;
 private final BroadcastReceiver personalReceiver=new BroadcastReceiver(){@Override public void onReceive(Context context,Intent intent){if(PersonalChangeSignal.ACTION.equals(intent.getAction()))metadataRefresh.request();}};
 private RecentLearningStore recentStore;private volatile RecentLearning.ScoringSnapshot recentLearning=new RecentLearning().scoringSnapshot();private volatile RecentLearningStore.PolicyState recentPolicy;private final ArrayList<RecentLearningStore.Selection> recentSelections=new ArrayList<>();private String recentReplica="";private final ArrayList<RecentLearningStore.Selection> recentIOPending=new ArrayList<>();private String recentIOEpoch="";private final java.util.concurrent.atomic.AtomicLong recentSnapshotRevision=new java.util.concurrent.atomic.AtomicLong();
 private LearningCoordinator learningCoordinator;private volatile boolean recoveryPrivate=false,destroyed=false;private volatile List<LearningModel.Entry> managed=Collections.emptyList();private List<LearningModel.Entry> appliedPins=Collections.emptyList();private Runnable learningRefresh;
 private static final class ShownChoice {final int document;final long version;final String raw;final CandidateViews.Item item;ShownChoice(int document,long version,String[][] state){this.document=document;this.version=version;raw=state[0][2];item=state.length>1?new CandidateViews.Item(state[1]):null;}}
 private volatile ShownChoice shownChoice;private boolean recoveryNoticeShown=false;
 private ChoiceMemory.Store choiceStore;private ChoiceMemory choiceMemory=new ChoiceMemory();private boolean choiceWritable=true;
 private String ownContext="";private final OwnCommitTracker ownTracker=new OwnCommitTracker();private volatile OwnCommitTracker.Replacement replacement;
 private static final class SelectionIntent {final String raw,code,text,reading,selected;final boolean corrected;String suffix="";SelectionIntent(String raw,String code,String text,String reading,String selected,boolean corrected){this.raw=raw;this.code=code;this.text=text;this.reading=reading;this.selected=selected;this.corrected=corrected;}}
 private SelectionIntent selectedIntent;

 private boolean dark(){return Ui.dark(this);}
 private int dp(float n){return Math.round(n*getResources().getDisplayMetrics().density);}
 private android.content.SharedPreferences preferences(){return getSharedPreferences("keyboard",0);}
 private final PersonalReset.Handler privacyReset=(done,error)->worker.execute(()->{
  try{
   if(learningRefresh!=null)main.removeCallbacks(learningRefresh);
   NativeCore.destroy(session);session=0;
   PersonalReset.apply(this);maintenance.reset(clipboardInputVisible,SystemClock.uptimeMillis());predictions.newDocument();
   choiceMemory=new ChoiceMemory();choiceWritable=true;choiceStore=new ChoiceMemory.Store(getFilesDir());
   personalStore=new PersonalLexicon(new File(getFilesDir(),"Shared"));personal=personalStore.load();
   learningCoordinator=new LearningCoordinator(getFilesDir(),new File(getFilesDir(),"Shared"));managed=Collections.emptyList();appliedPins=Collections.emptyList();recentStore=new RecentLearningStore(getFilesDir());recentSnapshotRevision.incrementAndGet();recentLearning=new RecentLearning().scoringSnapshot();recentPolicy=null;recentSelections.clear();recentReplica=learningCoordinator.replica();
   session=NativeCore.create(new File(getFilesDir(),"rime-v2").getAbsolutePath(),new File(getFilesDir(),"Rime").getAbsolutePath());
   if(session==0)throw new IOException("词库清理后暂时无法重新载入");
   NativeCore.mode(session,nine,privateInput);ownContext="";replacement=null;shownChoice=null;selectedIntent=null;
   ownTracker.invalidate();repairPlans.clear();context=ContextWindow.EMPTY;nativeSnapshot=new String[][]{{"","","","",""}};
   document++;inputEpoch.incrementAndGet();
   main.post(()->{ready=true;InputConnection connection=getCurrentInputConnection();if(marked&&connection!=null){connection.setComposingText("",1);connection.finishComposingText();}marked=false;snapshot=new String[][]{{"","","",""}};candidateItems.clear();expanded=false;render();});
  }catch(Exception failure){error[0]=failure;ready=false;}
  finally{done.countDown();}
 });
 @Override public void onCreate(){Ui.prepareTheme(this);super.onCreate();activityArchive=ActivityArchiveManager.get(this).inputProvider();clipboardCandidates=(ClipboardManager)getSystemService(Context.CLIPBOARD_SERVICE);if(clipboardCandidates!=null)try{clipboardCandidates.addPrimaryClipChangedListener(clipboardCandidateListener);}catch(RuntimeException denied){}PersonalReset.liveKeyboard=privacyReset;nine=preferences().getBoolean("nine",true);keyHeight=preferences().getInt("height",58);catalog=new Symbols(this);personalStore=new PersonalLexicon(new File(getFilesDir(),"Shared"));choiceStore=new ChoiceMemory.Store(getFilesDir());IntentFilter personalChanges=new IntentFilter(PersonalChangeSignal.ACTION);if(Build.VERSION.SDK_INT>=33)registerReceiver(personalReceiver,personalChanges,Context.RECEIVER_NOT_EXPORTED);else registerReceiver(personalReceiver,personalChanges);personalReceiverRegistered=true;try{ArrayList<String> words=new ArrayList<>();try(BufferedReader input=new BufferedReader(new InputStreamReader(getAssets().open("mixed-english.txt"),"UTF-8"))){String line;while((line=input.readLine())!=null)if(EnglishSuggestions.valid(line))words.add(line);}mixedEnglish=new EnglishSuggestions(words);}catch(IOException ignored){mixedEnglish=new EnglishSuggestions(Collections.emptyList());}
  worker.execute(()->{try{PersonalReset.apply(this);File shared=new File(getFilesDir(),"rime-v2"),user=new File(getFilesDir(),"Rime");user.mkdirs();if(!new File(shared,"ready").exists()){copyAssets("rime",shared);new File(shared,"ready").createNewFile();}try{quality=prepareLanguage();}catch(Exception ignored){quality=null;}
   session=NativeCore.create(shared.getAbsolutePath(),user.getAbsolutePath());if(session==0)throw new IOException("engine unavailable");try{NativeCore.languageInitialize(shared.getAbsolutePath());commonOrder=new CommonExpressionOrder(new File(shared,"essay.txt"),NativeCore::languageScore);}catch(IOException ignored){commonOrder=null;}try{learningCoordinator=new LearningCoordinator(getFilesDir(),new File(getFilesDir(),"Shared"));recentStore=new RecentLearningStore(getFilesDir());managed=learningCoordinator.entries();recentReplica=learningCoordinator.replica();refreshRecentLearning();recoveryPrivate=learningCoordinator.requiresPrivateRecovery();if(new File(getFilesDir(),"learning-maintenance-dirty-v1").exists())maintenance.localChanged();if(recoveryPrivate)synchronizeLearning(true);}catch(Exception error){if(learningCoordinator!=null)recoveryPrivate=learningCoordinator.requiresPrivateRecovery();}if(session==0)throw new IOException("engine unavailable");try{personal=personalStore.load();}catch(Exception unavailable){personal=null;}try{choiceMemory=choiceStore.load();}catch(Exception error){choiceWritable=false;}main.post(()->{if(destroyed)return;ready=true;configureEngine();metadataRefresh.request();});}catch(Exception e){main.post(()->{ready=false;render();});}});
 }
 private InputQuality prepareLanguage()throws Exception {
  File folder=new File(getFilesDir(),"public-language-v1");if(!folder.exists()&&!folder.mkdirs())throw new IOException("language directory");
  String[][] assets={{"pinyin-syllables.txt","ddd9b253b4f3412d17ed1c119d9d3b36f1153e7c3ff7f62e20e59cdfd1856689"},{"nine-lexicon.bin","33b4d52f97614a872d4670f380fd627e7a568a45bae161449e8733f9e7c97281"},{"continuation.bin","fed44db10df3f40ddd48f0ae3f6ffabcba72e163f6c641921d1f9e79b2daf7f4"}};
  for(String[] asset:assets) {
   File file=new File(folder,asset[0]);if(file.exists()&&sha256(file).equals(asset[1]))continue;
   android.util.AtomicFile atomic=new android.util.AtomicFile(file);FileOutputStream out=null;
   try {out=atomic.startWrite();try(InputStream in=getAssets().open(asset[0])){byte[] buffer=new byte[65536];int count;while((count=in.read(buffer))>0)out.write(buffer,0,count);}atomic.finishWrite(out);out=null;}
   catch(Exception error){if(out!=null)atomic.failWrite(out);throw error;}
   if(!sha256(file).equals(asset[1]))throw new IOException("language checksum");
  }
  return new InputQuality(folder);
 }
 private String sha256(File file)throws Exception {
  java.security.MessageDigest hash=java.security.MessageDigest.getInstance("SHA-256");try(InputStream in=new FileInputStream(file)){byte[] buffer=new byte[65536];int count;while((count=in.read(buffer))>0)hash.update(buffer,0,count);}
  StringBuilder value=new StringBuilder();for(byte b:hash.digest())value.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return value.toString();
 }
 private void copyAssets(String name,File output)throws IOException{String[] children=getAssets().list(name);if(children!=null&&children.length>0){if(!output.exists()&&!output.mkdirs())throw new IOException("resource directory");for(String item:children)copyAssets(name+"/"+item,new File(output,item));}else{File parent=output.getParentFile();parent.mkdirs();try(InputStream in=getAssets().open(name);OutputStream out=new FileOutputStream(output)){byte[] buf=new byte[65536];int n;while((n=in.read(buf))>0)out.write(buf,0,n);}}}
 @Override public View onCreateInputView(){root=new KeyboardRoot(this);root.setOrientation(1);if(Build.VERSION.SDK_INT>=30)stableNavigationBottom=getSystemService(WindowManager.class).getCurrentWindowMetrics().getWindowInsets().getInsetsIgnoringVisibility(WindowInsets.Type.navigationBars()).bottom;stableNavigationBottom=Math.max(dp(40),stableNavigationBottom);
  root.setPadding(dp(4),dp(4),dp(4),dp(8)+stableNavigationBottom);root.setBackgroundColor(Ui.rail(this));root.setOnApplyWindowInsetsListener((view,insets)->{int bottom=Build.VERSION.SDK_INT>=30?insets.getInsets(WindowInsets.Type.navigationBars()).bottom:insets.getSystemWindowInsetBottom();view.setPadding(dp(4),dp(4),dp(4),dp(8)+Math.max(bottom,stableNavigationBottom));return insets;});root.requestApplyInsets();render();return root;}
 @Override public boolean onEvaluateFullscreenMode(){return false;}
 @Override public void onWindowHidden(){clipboardInputVisible=false;maintenance.visible(false,SystemClock.uptimeMillis());scheduleLearning();stopClipboardHeartbeat();clipboardSuggestions.offer(document,null);shownClipboardCandidate=null;AutoClipboardBridge.get(this).imeActive(false);super.onWindowHidden();}
 @Override public void onWindowShown(){super.onWindowShown();clipboardInputVisible=true;maintenance.visible(true,SystemClock.uptimeMillis());if(learningRefresh!=null)main.removeCallbacks(learningRefresh);clipboardRefresh.reset();refreshClipboardCandidate();startClipboardHeartbeat();EditorInfo info=getCurrentInputEditorInfo();AutoClipboardBridge.get(this).imeActive(info!=null&&!secure&&(info.imeOptions&EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)==0);}

 @Override public void onStartInput(EditorInfo info,boolean restarting){if(PersonalReset.expired(this))ready=false;SyncTasks.worker.execute(()->{try{PersonalReset.deadline(this);}catch(Exception ignored){}});super.onStartInput(info,restarting);maintenance.visible(true,SystemClock.uptimeMillis());if(learningRefresh!=null)main.removeCallbacks(learningRefresh);Ui.refreshTheme(this);if(activityArchive!=null)activityArchive.start(info);boolean newDeletionSession=!restarting||deletionEditorField!=info.fieldId||!Objects.equals(deletionEditorPackage,info.packageName);deletionEditorField=info.fieldId;deletionEditorPackage=info.packageName;builtLayout="";document++;if(newDeletionSession)predictions.newDocument();dismissedContinuationEpoch=-1;ownContext="";replacement=null;ownTracker.invalidate();selectionStart=info.initialSelStart;selectionEnd=info.initialSelEnd;shownChoice=null;inputEpoch.incrementAndGet();context=ContextWindow.EMPTY;if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);marked=false;symbolRailContext="";symbolRailSnapshot=new String[0];nine=preferences().getBoolean("nine",true);keyHeight=Math.max(46,Math.min(76,preferences().getInt("height",58)));english=false;numbers=false;symbols=false;expanded=false;shift=false;int variation=info.inputType&InputType.TYPE_MASK_VARIATION;secure=(info.inputType&InputType.TYPE_MASK_CLASS)==InputType.TYPE_CLASS_NUMBER?variation==InputType.TYPE_NUMBER_VARIATION_PASSWORD:variation==InputType.TYPE_TEXT_VARIATION_PASSWORD||variation==InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD||variation==InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD;privateInput=secure||!preferences().getBoolean("learning",true)||(info.imeOptions&EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)!=0;numbers=(info.inputType&InputType.TYPE_MASK_CLASS)==InputType.TYPE_CLASS_NUMBER||(info.inputType&InputType.TYPE_MASK_CLASS)==InputType.TYPE_CLASS_PHONE;AutoClipboardBridge.get(this).imeActive(!secure&&(info.imeOptions&EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING)==0);snapshot=new String[][]{{"","","",""}};candidateItems.clear();clipboardSuggestions.bind(document);clipboardRefresh.reset();shownClipboardCandidate=null;nativeLoaded=0;moreCandidates=false;loadingMore=false;configureEngine();refreshClipboardCandidate();render();}
 private void configureEngine(){if(!ready){render();return;}final boolean useNine=nine,privateMode=privateInput;submit(()->{NativeCore.mode(session,useNine,privateMode||recoveryPrivate);applyPins();},false);metadataRefresh.request();}
 private void submit(Runnable action,boolean commit){submit(action,commit,null);}
 private void submit(Runnable action,boolean commit,Runnable after){submitLiteral(()->{action.run();return "";},commit,after);}
 private void submitLiteral(Callable<String> action,boolean commit,Runnable after){submitLiteral(action,commit,after,()->0);}
 private void submitLiteral(Callable<String> action,boolean commit,Runnable after,java.util.function.IntSupplier caretBack){submitLiteral(action,commit,after,caretBack,"edit");}
 private void submitLiteral(Callable<String> action,boolean commit,Runnable after,java.util.function.IntSupplier caretBack,String diagnosticKey){
  final ActivityArchiveManager.InputProvider traceProvider=activityArchive;final long traceToken=traceProvider==null||privateInput||recoveryPrivate||secure?0:traceProvider.diagnosticsToken();
  int target=document;long lifetime=predictions.inputLifetime(),cancellation=predictions.cancellation();boolean useNine=nine;String ownAtAction=ownContext;inputEpoch.incrementAndGet();browsing=false;if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);queuedInputActions.incrementAndGet();
  InputActionDelivery.execute(worker,()->target==document&&predictions.active(lifetime),()->{if(session==0)return;String traceBefore=traceToken!=0?NativeCore.draft(session)[0]:"";selectedIntent=null;String literal;try{literal=action.call();}catch(Exception error){main.post(()->{if(target==document)Toast.makeText(this,"输入处理未完成，请重试",Toast.LENGTH_SHORT).show();});return;}
   repairPlans.clear();long token=++version;String[][] nativeState=NativeCore.snapshot(session);if(traceToken!=0)traceProvider.diagnostic(traceToken,diagnosticKey,traceBefore,nativeState[0][2]);int loaded=nativeState.length-1;String[][] state=withChoices(withPins(withPersonal(nativeState,useNine)),ownAtAction);String[] readings=NativeCore.syllables(session);String output=nativeState[0][1]+literal;SelectionIntent selected=selectedIntent;
   if(!privateInput&&!recoveryPrivate&&(!nativeState[0][1].isEmpty()||selected!=null&&!literal.isEmpty()))nativeLearningChanged();
   main.post(()->InputActionDelivery.deliver(()->target==document&&predictions.active(lifetime),()->{InputConnection connection=getCurrentInputConnection();if(commit&&!output.isEmpty()&&connection!=null){if(connection.commitText(output,1)){if(activityArchive!=null)archiveCommitted(output);marked=false;confirmOwnCommit(connection,output,selected,ownAtAction,nativeState[0][2].isEmpty());finishSymbolCaret(connection,caretBack.getAsInt());}}},()->predictions.current(cancellation),()->{InputConnection connection=getCurrentInputConnection();nativeSnapshot=nativeState;snapshot=state;shownChoice=new ShownChoice(target,token,state);updateMarkedText(connection);syllables=readings;visibleVersion=token;nativeLoaded=loaded;moreCandidates=loaded==96;loadingMore=false;candidateItems.clear();for(int i=1;i<state.length;i++)candidateItems.add(new CandidateViews.Item(state[i]));if(state[0][2].isEmpty())expanded=false;render();if(candidateItems.isEmpty()&&moreCandidates)loadMore();scheduleQuality();},()->{if(after!=null)after.run();scheduleLearning();}));
  },()->main.post(this::inputActionFinished));
 }
 private void inputActionFinished(){queuedInputActions.decrementAndGet();updateCompositionClear();}
 private void freezeCandidates(){browsing=true;}
 private void scheduleQuality(){
  if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);
  if(!ready||quality==null||english||numbers||symbols||secure||browsing||predictions.suppressed()&&!pending())return;
  final int target=document;final long token=visibleVersion,epoch=inputEpoch.get();
  qualityRefresh=()->{
   if(target!=document||token!=visibleVersion||epoch!=inputEpoch.get()||browsing)return;
   context=captureContext();final ContextWindow surrounding=context;final boolean useNine=nine;
   final String[][] original=nativeSnapshot,augmented=snapshot;final String own=ownContext;
   worker.execute(()->{
    if(target!=document||token!=version||epoch!=inputEpoch.get()||browsing)return;
    Map<String,InputQuality.Repair> plans=new HashMap<>();String[][] predicted;
    if(original[0][2].isEmpty()) {
     if(privateInput||predictions.suppressed()||!preferences().getBoolean("context",true))return;
     List<PublicLanguageData.Suggestion> values=quality.suggestions(surrounding.before);
     predicted=new String[values.size()+1][];predicted[0]=augmented[0];
     for(int i=0;i<values.size();i++){String word=values.get(i).text;predicted[i+1]=new String[]{"continuation:"+word,word,"联想"};}
    }else {
     List<InputQuality.Repair> repairs=quality.repairs(session,original,useNine,surrounding.before,surrounding.after,()->target!=document||token!=version||epoch!=inputEpoch.get()||browsing);
     repairs=learnedRepairs(original,repairs,useNine,own);predicted=quality.merged(original,augmented,repairs,useNine,plans);
    }
    if(target!=document||token!=version||epoch!=inputEpoch.get()||browsing||predictions.suppressed()&&original[0][2].isEmpty())return;
    // Preserve bound completion plans already published in the first batch.
    for(String[] row:predicted)if(row.length>=3&&row[0].startsWith("repair:")&&!plans.containsKey(row[0])){InputQuality.Repair prior=repairPlans.get(row[0]);if(prior!=null&&prior.raw.equals(original[0][2])&&prior.text.equals(row[1])&&prior.reading.equals(row[2]))plans.put(row[0],prior);}
    final String[][] ranked=withChoices(withPins(predicted),own,plans);repairPlans.clear();repairPlans.putAll(plans);
    main.post(()->{
     if(target!=document||token!=visibleVersion||epoch!=inputEpoch.get()||browsing||predictions.suppressed()&&original[0][2].isEmpty())return;
     snapshot=ranked;shownChoice=new ShownChoice(target,token,ranked);candidateItems.clear();for(int i=1;i<ranked.length;i++)candidateItems.add(new CandidateViews.Item(ranked[i]));render();
    });
   });
  };
  main.postDelayed(qualityRefresh,70);
 }
 private ContextWindow captureContext(){
  if(privateInput||secure||!preferences().getBoolean("context",true))return ContextWindow.EMPTY;
  InputConnection connection=getCurrentInputConnection();if(connection==null)return ContextWindow.EMPTY;
  try {
   String composing=marked&&pending()?displayDraft():"";
   CharSequence before=connection.getTextBeforeCursor(80+Math.min(256,composing.length()),0),after=connection.getTextAfterCursor(80,0);
   return ContextWindow.excludingMarked(before==null?"":before.toString(),after==null?"":after.toString(),composing);
  }catch(RuntimeException ignored){return ContextWindow.EMPTY;}
 }
 private String[][] withChoices(String[][] rows,String own){return withChoices(rows,own,repairPlans);}
 private String[][] withChoices(String[][] rows,String own,Map<String,InputQuality.Repair> plans){
  rows=filterDisplayableRows(rows);
  if(!NativeCore.atEnd(session))return rows;
  long now=SystemClock.elapsedRealtime();String code=rows.length>0&&rows[0].length>2?NineSpelling.rawCode(rows[0][2]):null;
  boolean explicitRetry=replacement!=null&&replacement.current(document,now,own)&&replacement.rejected!=null&&replacement.reading!=null&&replacement.code.equals(code);
  if(commonOrder!=null&&!explicitRetry){final String inputCode=code;rows=commonOrder.apply(rows,nine,privateInput||!preferences().getBoolean("context",true)?"":context.before,row->!privateInput&&!recoveryPrivate&&(isPinned(new CandidateViews.Item(row))||choiceWritable&&inputCode!=null&&choiceMemory.boost(inputCode,row[2],row[1],own)>0));}
  if(privateInput||recoveryPrivate||!choiceWritable)return withPrefixCompletions(rows,own,explicitRetry,plans);
  RecentLearning.Policy policy=null;if(recentPolicy!=null&&recentPolicy.publishEnabled){RecentLearningStore.Usage clock=RecentLearningStore.usage(this);Integer day=recentPolicy.clock.day(clock.wallSeconds,clock.uptime,clock.bootSession);if(day!=null&&recentPolicy.policy.accepts(day))policy=recentPolicy.policy;}final RecentLearning.Policy scoringPolicy=policy;
  rows=ChoiceOrder.apply(rows,own,choiceMemory,replacement,document,now,this::isPinned,item->recentLearning.score(item.reading,item.text,scoringPolicy));return withPrefixCompletions(rows,own,explicitRetry,plans);
 }
 private String[][] withPrefixCompletions(String[][] rows,String own,boolean explicitRetry,Map<String,InputQuality.Repair> plans){
  if(!nine||english||numbers||symbols||secure||explicitRetry||quality==null||commonOrder==null||rows.length==0||rows[0].length<5)return rows;
  String code=NineSpelling.rawCode(rows[0][2]);boolean protectedHead=false;
  if(rows.length>1){if(!rows[1][0].matches("[0-9]+"))return rows;CandidateViews.Item head=new CandidateViews.Item(rows[1]);protectedHead=!privateInput&&!recoveryPrivate&&(isPinned(head)||choiceWritable&&code!=null&&choiceMemory.boost(code,head.reading,head.text,own)>0);}
  List<InputQuality.Repair> additions=quality.prefixCompletions(session,rows,protectedHead,commonOrder::frequency);
  ArrayList<String[]> output=new ArrayList<>();output.add(rows[0].clone());Set<String> seen=new HashSet<>();
  for(InputQuality.Repair addition:additions)if(candidateDisplayable(addition.text)&&seen.add(addition.text)){String id=InputQuality.repairID(addition);plans.put(id,addition);output.add(new String[]{id,addition.text,addition.reading});}
  if(output.size()==1)return rows;
  for(int i=1;i<rows.length;i++)if(seen.add(rows[i][1]))output.add(rows[i]);
  long offset=NativeCore.editableStart(session);String raw=rows[0][2];if(offset>=0&&offset<=raw.length())output.get(0)[3]=rows[0][4]+InputQuality.prefixReading(raw.substring((int)offset),output.get(1)[2]);
  return output.toArray(new String[0][]);
 }
 private java.math.BigInteger confirmedLearningGeneration(String reading,String text){String id=LearningModel.canonical(reading.toLowerCase(Locale.ROOT)+'\u001f'+text);for(LearningModel.Entry entry:managed)if(entry.id().equals(id))return entry.generation;RecentLearning.Entry entry=recentLearning.get(reading,text);return entry==null?java.math.BigInteger.ZERO:entry.generation;}
 private SelectionIntent intent(CandidateViews.Item item,boolean corrected){String[] draft=NativeCore.draft(session);if(draft.length<2||item.reading.trim().isEmpty())return null;long start=NativeCore.editableStart(session);if(start<0&&draft[1].isEmpty())start=0;if(start<0||start>draft[0].length())return null;String code=NineSpelling.rawCode(draft[0].substring((int)start));return code==null?null:new SelectionIntent(draft[0],code,item.text,item.reading,draft[1],corrected);}
 private static final class HostAnchor {final String before,after;HostAnchor(String before,String after){this.before=before;this.after=after;}}
 private String digest(String value){try{byte[] bytes=java.security.MessageDigest.getInstance("SHA-256").digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();for(byte b:bytes)out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();}catch(Exception impossible){throw new IllegalStateException(impossible);}}
 private HostAnchor anchor(InputConnection c,String ownSuffix){if(c==null)return null;try{CharSequence selected=c.getSelectedText(0),before=c.getTextBeforeCursor(ownSuffix.length()+128,0),after=c.getTextAfterCursor(128,0);if(selected!=null&&selected.length()>0||before==null||after==null||!before.toString().endsWith(ownSuffix))return null;String prefix=before.toString().substring(0,before.length()-ownSuffix.length());List<String> tail=OwnText.characters(after.toString());return new HostAnchor(digest(OwnText.suffix(prefix,16)),digest(String.join("",tail.subList(0,Math.min(16,tail.size())))));}catch(RuntimeException unavailable){return null;}}
 private void validateOwnContext(){if(privateInput||recoveryPrivate){ownContext="";ownTracker.invalidate();replacement=null;return;}if(ownContext.isEmpty())return;InputConnection c=getCurrentInputConnection();try{String suffix=OwnText.suffix(ownContext,16);CharSequence before=c==null?null:c.getTextBeforeCursor(suffix.length(),0);if(before==null||!before.toString().endsWith(suffix)){ownContext="";ownTracker.invalidate();replacement=null;}}catch(RuntimeException unavailable){ownContext="";ownTracker.invalidate();replacement=null;}}
 private void prepareOwnTyping(){validateOwnContext();long now=SystemClock.elapsedRealtime();String expected=ownTracker.expected(document,now);HostAnchor proof=expected==null?null:anchor(getCurrentInputConnection(),expected);if(proof!=null){OwnCommitTracker.Replacement partial=ownTracker.partial(document,proof.before,proof.after,now);if(partial!=null){replacement=partial;ownContext=partial.context;}}ownTracker.invalidate();}
 private void literal(String value){literal(value,0);}
 private void archiveCommitted(String text){if(activityArchive==null)return;activityArchive.layout(numbers?"numbers":symbols?"symbols":english?"english26":nine?"nine":"letters");activityArchive.committed(text,true);}
 private void literal(String value,int caretBack){if(activityArchive!=null&&!privateInput&&!recoveryPrivate&&!secure){long token=activityArchive.diagnosticsToken();activityArchive.diagnostic(token,"literal:"+value,"","");}validateOwnContext();ownTracker.invalidate();replacement=null;InputConnection c=getCurrentInputConnection();if(c!=null&&c.commitText(value,1)){if(activityArchive!=null)archiveCommitted(value);ownContext=privateInput||secure||recoveryPrivate?"":OwnText.append(value,ownContext);finishSymbolCaret(c,caretBack);}}
 private void confirmOwnCommit(InputConnection c,String output,SelectionIntent chosen,String ownAtAction,boolean completed){
  ownTracker.invalidate();if(privateInput||secure||recoveryPrivate){ownContext="";replacement=null;return;}
  HostAnchor proof=anchor(c,output);String previous=ownAtAction;try{String suffix=OwnText.suffix(previous,16);CharSequence before=c.getTextBeforeCursor(output.length()+suffix.length(),0);if(before==null||!before.toString().endsWith(suffix+output))previous="";}catch(RuntimeException unavailable){previous="";}
  OwnCommitTracker.Replacement retry=replacement;replacement=null;ownContext=OwnText.append(output,previous);
  if(chosen==null||!output.equals(chosen.selected+chosen.text+chosen.suffix))return;
  final RecentLearningStore.Usage usage=RecentLearningStore.usage(this);final String recentEpoch=PersonalReset.generation(this);
  worker.execute(()->{if(recentStore==null||learningCoordinator==null||recoveryPrivate||!recentEpoch.equals(PersonalReset.generation(this)))return;try{if(recentSelections.size()<5000&&!recentReplica.isEmpty())recentSelections.add(new RecentLearningStore.Selection(chosen.reading,chosen.text,recentReplica,confirmedLearningGeneration(chosen.reading,chosen.text),recentPolicy,usage));refreshRecentLearning();}catch(Exception unsupportedSelection){/* Cumulative native learning remains independent. */}});
  String local=OwnText.append(chosen.selected,previous);int target=document;long now=SystemClock.elapsedRealtime();
  final String choiceEpoch=PersonalReset.generation(this);if(choiceWritable)worker.execute(()->{if(!choiceWritable||!choiceEpoch.equals(PersonalReset.generation(this)))return;try{String correct=NineSpelling.encode(chosen.reading);if(correct==null||!ChoiceMemory.canRecord(chosen.code,chosen.reading,chosen.text,local))return;LinkedHashSet<String> codes=new LinkedHashSet<>();codes.add(chosen.code);boolean related=retry!=null&&retry.current(target,now,local)&&NineSpelling.jointEditCost(retry.code,correct)!=null;if(related)codes.add(retry.code);boolean correction=related&&retry.rejected!=null&&!OwnText.equal(retry.rejected,chosen.text);if(chosen.corrected||codes.size()>1||correction)codes.add(correct);int strength=correction?3:chosen.corrected||codes.size()>1?2:1;choiceMemory=choiceStore.change(old->{ChoiceMemory next=old;for(String code:codes)if(NineSpelling.jointEditCost(code,correct)!=null)next=next.record(code,chosen.reading,chosen.text,local,strength,correction);return next;});}catch(Exception error){choiceWritable=false;}});
  String code=NineSpelling.rawCode(chosen.raw);if(completed&&chosen.suffix.isEmpty()&&proof!=null&&code!=null)ownTracker.stage(document,proof.before,proof.after,output,code,previous,now,output.equals(chosen.text)?chosen.reading:null);
 }
 private List<InputQuality.Repair> learnedRepairs(String[][] original,List<InputQuality.Repair> ordinary,boolean useNine,String own){
  if(privateInput||recoveryPrivate||!choiceWritable||original[0].length<5||!original[0][4].isEmpty()||!NativeCore.atEnd(session))return ordinary;String raw=original[0][2],code=NineSpelling.rawCode(raw);if(code==null||!raw.matches(useNine?"[2-9]+":"[a-z]+"))return ordinary;
  ArrayList<ChoiceMemory.Entry> remembered=new ArrayList<>();for(ChoiceMemory.Entry e:choiceMemory.entries)if(e.code.equals(code)&&!code.equals(NineSpelling.encode(e.reading)))remembered.add(e);remembered.sort((a,b)->Double.compare(choiceMemory.boost(code,b.reading,b.text,own),choiceMemory.boost(code,a.reading,a.text,own)));ArrayList<InputQuality.Repair> result=new ArrayList<>(ordinary);Set<String> texts=new HashSet<>();for(InputQuality.Repair r:ordinary)texts.add(r.text);int queries=0;
  for(ChoiceMemory.Entry e:remembered){if(queries++>=6)break;for(String[] row:NativeCore.query(session,e.reading,false,64))if(OwnText.equal(row[1],e.text)&&quality.exact(e.reading,row[2],false)){if(texts.add(row[1]))result.add(new InputQuality.Repair(raw,InputQuality.normalized(row[2]),row[1],row[2],"",4+choiceMemory.boost(code,row[2],row[1],own)));break;}}
  result.sort((a,b)->Double.compare(b.score,a.score));return result;
 }
 private String commitRepair(InputQuality.Repair repair){
  if(repair==null)return "";
  String[] accepted=NativeCore.commitAlternative(session,repair.raw,repair.spelling,repair.text,repair.remainder);
  if(accepted.length!=2)return "";session=Long.parseLong(accepted[0]);return accepted[1];
 }
 private void applyPins(){
  for(LearningModel.Entry entry:appliedPins)NativeCore.pin(entry.reading,entry.text,false);
  ArrayList<LearningModel.Entry> next=new ArrayList<>();for(LearningModel.Entry entry:managed)if(!entry.deleted&&entry.pinned){NativeCore.pin(entry.reading,entry.text,true);next.add(entry);}appliedPins=next;
 }
 private boolean isPinned(CandidateViews.Item item){String reading=item.reading.toLowerCase(Locale.ROOT).trim();for(LearningModel.Entry entry:managed)if(!entry.deleted&&entry.pinned&&entry.reading.equals(reading)&&entry.text.equals(item.text))return true;return false;}
 private String[][] withPins(String[][] rows){
  if(privateInput||recoveryPrivate||managed.isEmpty()||rows.length<2)return rows;ArrayList<String[]> result=new ArrayList<>();Set<String> ids=new HashSet<>();result.add(rows[0]);
  for(int i=1;i<rows.length;i++)if(rows[i][0].startsWith("custom:")){result.add(rows[i]);ids.add(rows[i][0]);}
  for(int i=1;i<rows.length;i++)if(!ids.contains(rows[i][0])&&isPinned(new CandidateViews.Item(rows[i]))){result.add(rows[i]);ids.add(rows[i][0]);}
  for(int i=1;i<rows.length;i++)if(ids.add(rows[i][0]))result.add(rows[i]);return result.toArray(new String[0][]);
 }
 private void manageCandidate(View anchor,CandidateViews.Item item,long token){
  if(privateInput||recoveryPrivate||learningCoordinator==null||item.id.startsWith("custom:")||item.id.startsWith("english:")||item.id.startsWith("continuation:")||!item.reading.matches("[a-zA-Z ']+")||item.reading.trim().isEmpty())return;
  freezeCandidates();PopupMenu menu=new PopupMenu(this,anchor);boolean pinned=isPinned(item);
  menu.getMenu().add(pinned?"取消置顶":"置顶候选").setOnMenuItemClickListener(value->{manage(item,token,!pinned);return true;});
  menu.getMenu().add("恢复默认词频").setOnMenuItemClickListener(value->{manage(item,token,null);return true;});menu.show();
 }
 private void manage(CandidateViews.Item item,long token,Boolean pinned){
  if(pinned==null){ownTracker.invalidate();replacement=null;}final int target=document;final boolean useNine=nine;final String own=ownContext;final String[][] visible=new String[candidateItems.size()+1][];visible[0]=snapshot[0];for(int i=0;i<candidateItems.size();i++){CandidateViews.Item row=candidateItems.get(i);visible[i+1]=new String[]{row.id,row.text,row.reading};}
  final long epoch=inputEpoch.incrementAndGet(),cancellation=predictions.cancellation();browsing=true;if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);
  worker.execute(()->{
   if(target!=document||version!=token||!predictions.current(cancellation)||privateInput||recoveryPrivate)return;
   try {
    learningCoordinator.manage(item.reading.toLowerCase(Locale.ROOT).trim(),item.text,pinned);nativeLearningChanged();if(pinned==null&&choiceWritable)try{choiceMemory=choiceStore.change(old->old.reset(item.text,item.reading));}catch(Exception error){choiceWritable=false;}managed=learningCoordinator.entries();recentSnapshotRevision.incrementAndGet();recentLearning=new RecentLearning().scoringSnapshot();recentPolicy=null;refreshRecentLearning();applyPins();final String[][] nativeState=NativeCore.snapshot(session);final String[] readings=NativeCore.syllables(session);
    ArrayList<InputQuality.Repair> previous=new ArrayList<>();for(int i=1;i<visible.length;i++){InputQuality.Repair plan=repairPlans.get(visible[i][0]);if(plan!=null&&plan.raw.equals(nativeState[0][2])&&plan.text.equals(visible[i][1])&&plan.reading.equals(visible[i][2]))previous.add(plan);}
    Map<String,InputQuality.Repair> plans=new HashMap<>();String[][] ordinary=withPersonal(nativeState,useNine);String[][] rows=withChoices(withPins(quality==null?ordinary:quality.merged(nativeState,ordinary,previous,useNine,plans)),own);repairPlans.putAll(plans);
    // Pinning changes the logical native stream, so continuation restarts from
    // this new first batch; every later item still uses its absolute native ID.
    main.post(()->{if(target!=document||visibleVersion!=token||epoch!=inputEpoch.get()||!predictions.current(cancellation)||destroyed)return;InputConnection connection=getCurrentInputConnection();if(!nativeState[0][1].isEmpty()&&connection!=null){if(connection.commitText(nativeState[0][1],1)&&activityArchive!=null)archiveCommitted(nativeState[0][1]);marked=false;}nativeSnapshot=nativeState;snapshot=rows;syllables=readings;shownChoice=new ShownChoice(target,token,rows);nativeLoaded=nativeState.length-1;moreCandidates=nativeLoaded==96;loadingMore=false;candidateItems.clear();for(int i=1;i<rows.length;i++)candidateItems.add(new CandidateViews.Item(rows[i]));updateMarkedText(connection);render();if(candidateGrid!=null)candidateGrid.setSelection(0);scheduleLearning();if(pinned==null)Toast.makeText(this,"下次输入使用默认词频",Toast.LENGTH_SHORT).show();});
   }catch(Exception error){main.post(()->{if(!destroyed&&target==document)Toast.makeText(this,"暂时无法保存输入记忆，请稍后重试",Toast.LENGTH_SHORT).show();});}
  });
 }
 private void nativeLearningChanged(){maintenance.localChanged();File flag=new File(getFilesDir(),"learning-maintenance-dirty-v1");if(!flag.exists())try(FileOutputStream out=new FileOutputStream(flag)){out.write(1);out.getFD().sync();}catch(IOException unavailable){/* Native userdb remains durable; retry the derived checkpoint later. */}main.post(this::scheduleLearning);}
 private void scheduleLearning(){
  if(learningRefresh!=null)main.removeCallbacks(learningRefresh);if(learningCoordinator==null||destroyed||(privateInput&&!recoveryPrivate))return;long delay=maintenance.delay(SystemClock.uptimeMillis());if(delay<0)return;
  learningRefresh=()->worker.execute(()->{if(!destroyed)synchronizeLearning(false);});main.postDelayed(learningRefresh,delay);
 }
 /** Worker only. Queued key actions run after the session is always recreated. */
 private void synchronizeLearning(boolean coldRecovery){
  if(learningCoordinator==null||session==0||(!coldRecovery&&privateInput&&!recoveryPrivate)||NativeCore.hasPending(session))return;
  LearningMaintenanceState.Ticket ticket=maintenance.begin(SystemClock.uptimeMillis(),coldRecovery,false);if(ticket==null)return;if(!maintenance.mayStart(ticket)||!NativeCore.closeForCheckpoint(session)){maintenance.finish(ticket,false);return;}boolean completed=false;session=0;File work=new File(getCacheDir(),"learning-"+UUID.randomUUID());
  try {
   managed=learningCoordinator.checkpoint(new LearningCoordinator.Engine(){public int exportTo(File file){return NativeCore.exportLearning(file.getAbsolutePath());}public int importFrom(File file){return NativeCore.importLearning(file.getAbsolutePath());}public int reset(LearningModel.Entry entry){return NativeCore.resetFrequency(entry.reading,entry.text,entry.frequency());}},work,!coldRecovery&&!privateInput);
   completed=true;recoveryPrivate=false;refreshRecentLearning();try{PersonalLexicon.Snapshot next=personalStore.load();boolean changed=personal==null||!personal.encode().equals(next.encode());personal=next;if(changed)PersonalChangeSignal.notifyChanged(getApplicationContext());}catch(Exception ignored){}
  }catch(Exception error){recoveryPrivate=learningCoordinator.requiresPrivateRecovery();}
  finally {
   maintenance.finish(ticket,completed);if(completed&&!maintenance.localPending())new File(getFilesDir(),"learning-maintenance-dirty-v1").delete();metadataRefresh.request();main.post(this::scheduleLearning);
   session=NativeCore.create(new File(getFilesDir(),"rime-v2").getAbsolutePath(),new File(getFilesDir(),"Rime").getAbsolutePath());
   if(session!=0){NativeCore.mode(session,nine,privateInput||recoveryPrivate);applyPins();if(recoveryPrivate&&!recoveryNoticeShown){recoveryNoticeShown=true;main.post(()->{if(!destroyed)Toast.makeText(this,"输入记忆暂不可写，仍可继续输入",Toast.LENGTH_LONG).show();});}else if(!recoveryPrivate)recoveryNoticeShown=false;}
   else main.post(()->{if(!destroyed){ready=false;render();Toast.makeText(this,"词库暂时无法重载，请切换键盘后重试",Toast.LENGTH_LONG).show();}});
   for(String name:new String[]{"engine.tsv","incoming.tsv"})new File(work,name).delete();work.delete();
  }
 }

 private void refreshRecentLearning(){
  if(recentStore==null||recentIO.isShutdown())return;long revision=recentSnapshotRevision.incrementAndGet();String privacy=PersonalReset.generation(this),legacy=learningCoordinator==null?null:learningCoordinator.completedArchive();
  synchronized(recentStageLock){if(!privacy.equals(recentStagedEpoch)){recentStaged.clear();recentStagedEpoch=privacy;}for(RecentLearningStore.Selection value:recentSelections)if(recentStaged.size()<5000)recentStaged.add(value);recentSelections.clear();recentStagedLegacy=legacy;recentStagedRevision=revision;}recentRefresh.request();
 }
 private void readRecentBatch(long ignored){
  final String privacy,legacy;final long revision;final List<RecentLearningStore.Selection> batch;
  synchronized(recentStageLock){privacy=recentStagedEpoch;legacy=recentStagedLegacy;revision=recentStagedRevision;batch=new ArrayList<>(recentStaged);recentStaged.clear();}
  if(recentStore==null||!privacy.equals(PersonalReset.generation(this)))return;
  if(!privacy.equals(recentIOEpoch)){recentIOPending.clear();recentIOEpoch=privacy;}for(RecentLearningStore.Selection event:batch)if(recentIOPending.size()<5000)recentIOPending.add(event);
  try{RecentLearningStore.usage(this);RecentLearningStore.Snapshot loaded=legacy==null?recentStore.snapshot():recentStore.mergeLegacy(legacy);if(!recentIOPending.isEmpty()){loaded=recentStore.recordChoices(Collections.unmodifiableList(new ArrayList<>(recentIOPending)));recentIOPending.clear();}RecentLearningStore.PolicyState policy=recentStore.policySnapshot();if(privacy.equals(PersonalReset.generation(this))&&!destroyed&&revision==recentSnapshotRevision.get()){recentLearning=loaded.model.scoringSnapshot();recentPolicy=policy;}}
  catch(Exception unavailable){if(privacy.equals(PersonalReset.generation(this)))recentPolicy=null;}
 }
 private void readMetadata(long revision){
  if(destroyed||learningCoordinator==null||personalStore==null)return;String privacy=PersonalReset.generation(this);long scoreRevision=recentSnapshotRevision.get();
  try{PersonalLexicon.Snapshot next=personalStore.load();String completed=learningCoordinator.completedArchive(),incoming=new LearningSnapshotFile(new File(getFilesDir(),"Shared")).read();LearningModel model=new LearningModel();if(completed!=null)model.merge(completed);if(incoming!=null)model.merge(incoming);String merged=model.export();List<LearningModel.Entry> nextManaged=model.entries();RecentLearningStore.Snapshot recent=recentStore==null?null:recentStore.snapshot();RecentLearningStore.PolicyState policy=recentStore==null?null:recentStore.policySnapshot();
   if(!metadataRefresh.current(revision)||!privacy.equals(PersonalReset.generation(this))||destroyed)return;maintenance.remoteSnapshot(digest(merged),incoming!=null&&!merged.equals(completed));main.post(this::scheduleLearning);
   worker.execute(()->{if(!metadataRefresh.current(revision)||!privacy.equals(PersonalReset.generation(this))||destroyed)return;personal=next;managed=nextManaged;recentPolicy=policy;if(recent!=null&&scoreRevision==recentSnapshotRevision.get())recentLearning=recent.model.scoringSnapshot();if(ready&&session!=0&&!NativeCore.hasPending(session))applyPins();});
  }catch(Exception unavailable){/* Existing immutable frontend snapshots remain usable. */}
 }

 private String[][] withPersonal(String[][] nativeState,boolean useNine){
  if(nativeState[0].length<5||!nativeState[0][4].isEmpty()||nativeState[0][2].isEmpty())return nativeState;
  List<PersonalLexicon.Entry> matches=personal==null?Collections.emptyList():personal.matches(nativeState[0][2],useNine);List<String> englishRows=preferences().getBoolean("mixed",true)?mixedEnglish.suggestions(nativeState[0][2],useNine):Collections.emptyList();if(matches.isEmpty()&&englishRows.isEmpty())return nativeState;
  ArrayList<String[]> result=new ArrayList<>();String[] meta=nativeState[0].clone();if(useNine&&!matches.isEmpty())meta[3]=matches.get(0).trigger;result.add(meta);Set<String> used=new HashSet<>();for(PersonalLexicon.Entry entry:matches){result.add(new String[]{"custom:"+entry.id,entry.text,entry.trigger});used.add(entry.text);}int split=Math.min(nativeState.length,6);for(int i=1;i<split;i++)if(!used.contains(nativeState[i][1])){result.add(nativeState[i]);used.add(nativeState[i][1]);}for(String word:englishRows)if(used.add(word))result.add(new String[]{"english:"+word,word,"英文"});for(int i=split;i<nativeState.length;i++)if(!used.contains(nativeState[i][1]))result.add(nativeState[i]);return result.toArray(new String[0][]);
 }
 private String acceptFirst(){
  if(!NativeCore.hasPending(session))return "";String[] draft=NativeCore.draft(session);ShownChoice shown=shownChoice;
  if(shown!=null&&shown.document==document&&shown.version==version&&shown.raw.equals(draft[0])&&shown.item!=null)return selectKnown(shown.item);
  if(personal!=null&&draft[1].isEmpty()){List<PersonalLexicon.Entry> matches=personal.matches(draft[0],nine);for(PersonalLexicon.Entry match:matches)if(candidateDisplayable(match.text)){NativeCore.clear(session);return match.text;}}
  String[][] fallback=filterDisplayableRows(NativeCore.snapshot(session));if(fallback.length>1){CandidateViews.Item first=new CandidateViews.Item(fallback[1]);selectedIntent=intent(first,false);NativeCore.choose(session,Long.parseLong(first.id));return "";}selectedIntent=null;
  if(draft[1].isEmpty()&&preferences().getBoolean("mixed",true)){List<String> words=mixedEnglish.suggestions(draft[0],nine);if(!words.isEmpty()){NativeCore.clear(session);return words.get(0);}}
  return "";
 }
 private String selectKnown(CandidateViews.Item item){
  if(item.id.startsWith("repair:")){InputQuality.Repair plan=repairPlans.get(item.id);if(plan==null||!plan.text.equals(item.text)||!plan.reading.equals(item.reading))return "";selectedIntent=intent(item,!plan.prefixCompletion);return commitRepair(plan);}
  if(item.id.startsWith("continuation:")){if(!predictions.suppressed()&&!NativeCore.hasPending(session)&&!privateInput&&quality!=null&&quality.suggestions(context.before).stream().anyMatch(value->value.text.equals(item.text)))return item.text;return "";}
  if(item.id.startsWith("english:")){String[] draft=NativeCore.draft(session);if(draft[1].isEmpty()&&preferences().getBoolean("mixed",true)&&mixedEnglish.suggestions(draft[0],nine).contains(item.text)){NativeCore.clear(session);return item.text;}return "";}
  if(item.id.startsWith("custom:")&&personal!=null){String[] draft=NativeCore.draft(session);if(!draft[1].isEmpty())return "";for(PersonalLexicon.Entry entry:personal.matches(draft[0],nine))if(item.id.equals("custom:"+entry.id)&&item.text.equals(entry.text)){NativeCore.clear(session);return entry.text;}return "";}
  if(item.id.matches("[0-9]+")){selectedIntent=intent(item,false);NativeCore.choose(session,Long.parseLong(item.id));}return "";
 }
 private void loadMore(){
  if(!moreCandidates||loadingMore||!pending()||english||secure)return;loadingMore=true;int target=document,offset=nativeLoaded;long token=visibleVersion,cancellation=predictions.cancellation();
  worker.execute(()->{if(target!=document||version!=token||!predictions.current(cancellation)){main.post(()->{if(target==document&&visibleVersion==token)loadingMore=false;});return;}String[][] unfiltered=NativeCore.more(session,offset);int pageCount=unfiltered.length;ArrayList<String[]> supported=new ArrayList<>();for(String[] row:unfiltered)if(candidateDisplayable(row[1]))supported.add(row);String[][] page=supported.toArray(new String[0][]);main.post(()->{if(target!=document||visibleVersion!=token||!predictions.current(cancellation))return;loadingMore=false;nativeLoaded+=pageCount;moreCandidates=pageCount==96;Set<String> ids=new HashSet<>();for(CandidateViews.Item item:candidateItems)ids.add(item.id);Set<String> customText=new HashSet<>();for(CandidateViews.Item item:candidateItems)if(item.id.startsWith("custom:"))customText.add(item.text);for(String[] row:page)if(ids.add(row[0])&&!customText.contains(row[1]))candidateItems.add(new CandidateViews.Item(row));if(candidateStrip==null&&!candidateItems.isEmpty())render();else if(candidateStrip!=null)candidateStrip.update(candidateItems,false);if(candidateGrid!=null)candidateGrid.update(candidateItems);if(candidateItems.isEmpty()&&moreCandidates)loadMore();});});
 }
 private void updateMarkedText(InputConnection connection){if(connection==null)return;boolean inline=preferences().getBoolean("inline",false)&&!english&&!secure&&!numbers;String text=pending()?displayDraft():"";if(inline&&!text.isEmpty()){connection.setComposingText(text,1);marked=true;}else if(marked){connection.setComposingText("",1);connection.finishComposingText();marked=false;}}
 private void feedback(View view){String mode=preferences().getString("feedback","light");if(!mode.equals("off"))view.performHapticFeedback(mode.equals("strong")?HapticFeedbackConstants.KEYBOARD_TAP:HapticFeedbackConstants.CLOCK_TICK);}
 private boolean switchIdleMode(boolean nextEnglish,boolean nextNumbers){if(!ready||pending()||queuedInputActions.get()!=0)return false;inputEpoch.incrementAndGet();if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);english=nextEnglish;numbers=nextNumbers;symbols=false;expanded=false;candidateItems.clear();render();scheduleQuality();return true;}
 private void language(){if(secure)return;boolean next=!english;if(switchIdleMode(next,false))return;submitLiteral(()->next?acceptFirst():"",true,()->{if(next&&pending())return;english=next;numbers=false;symbols=false;render();});}
 private void numeric(){boolean next=!numbers;if(switchIdleMode(english,next))return;submitLiteral(()->next?acceptFirst():"",true,()->{if(next&&pending())return;numbers=next;symbols=false;render();});}
 private boolean pending(){return snapshot.length>0&&snapshot[0].length>2&&!snapshot[0][2].isEmpty();}
 private String visibleDraft(){String text=displayDraft();if(!nine&&nativeSnapshot[0].length>5)try{int caret=Integer.parseInt(nativeSnapshot[0][5]);if(caret>=0&&caret<text.length())return text.substring(0,caret)+"┃"+text.substring(caret);}catch(NumberFormatException ignored){}return text;}
 private void updateCompositionClear(){boolean enabled=PredictionSuppression.canClear(pending(),queuedInputActions.get(),auxiliaryCandidatesShown);for(Button key:compositionClearKeys){key.setEnabled(enabled);key.setAlpha(enabled?1:0.45f);}}
 private String displayDraft(){String[][] draft=preferences().getBoolean("inline",false)?nativeSnapshot:snapshot;
  if(nine&&snapshot.length>1){InputQuality.Repair first=repairPlans.get(snapshot[1][0]);if(first!=null&&first.prefixCompletion&&first.raw.equals(nativeSnapshot[0][2]))draft=snapshot;}
  String text=nine?draft[0][3]:draft[0][0];return text.isEmpty()?snapshot[0][2]:text;}
 private void input(int key){if(!ready)return;resumeSuggestionsForExplicitEdit();if(english||numbers||secure){literal(String.valueOf((char)key));return;}if(!pending()&&key!=32)prepareOwnTyping();
  submitLiteral(()->{if(key==32)return NativeCore.hasPending(session)?acceptFirst():" ";NativeCore.key(session,key);return "";},true,null,()->0,String.valueOf((char)key));}

 private void eraseCommitted(){if(activityArchive!=null){if(!privateInput&&!recoveryPrivate&&!secure){long token=activityArchive.diagnosticsToken();activityArchive.diagnostic(token,"backspace","","");}activityArchive.uncertainEdit();}InputConnection c=getCurrentInputConnection();if(c==null)return;long now=SystemClock.elapsedRealtime();String remaining=!privateInput&&!recoveryPrivate&&!english&&!numbers?ownTracker.expected(document,now):null;HostAnchor before=remaining==null?null:anchor(c,remaining);boolean tracked=before!=null&&ownTracker.anchored(document,before.before,before.after,now);ownContext="";replacement=null;
  if(!c.deleteSurroundingTextInCodePoints(1,0)){c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_DEL));c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_DEL));}
  HostAnchor after=tracked?anchor(c,OwnText.dropLast(remaining)):null;if(after!=null&&before.before.equals(after.before)&&before.after.equals(after.after)){replacement=ownTracker.deleted(document,before.before,before.after,now);ownContext=ownTracker.remainingContext();}else ownTracker.invalidate();
 }
 private void erase(){boolean clipboardVisible=!pending()&&shownClipboardCandidate!=null;predictions.deleting();
  if(!pending()&&(clipboardVisible||candidateItems.stream().anyMatch(item->item.id.startsWith("continuation:")))){if(clipboardVisible)clipboardSuggestions.consume(document,shownClipboardCandidate.id);freezeCandidates();dismissedContinuationEpoch=inputEpoch.incrementAndGet();if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);candidateItems.clear();shownClipboardCandidate=null;shownChoice=null;expanded=false;snapshot=new String[][]{snapshot[0]};if(!clipboardVisible){dismissedContinuationEpoch=-1;eraseCommitted();}render();return;}
  if(english||numbers||secure){dismissedContinuationEpoch=-1;eraseCommitted();return;}
  // A continuation dismissal proves there was no native composition. If no
  // subsequent input changed that epoch, the next delete can edit the host
  // immediately instead of waiting behind an unrelated Rime checkpoint.
  if(!pending()&&dismissedContinuationEpoch==inputEpoch.get()){dismissedContinuationEpoch=-1;inputEpoch.incrementAndGet();if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);eraseCommitted();return;}
  dismissedContinuationEpoch=-1;boolean[] removeText={false};submit(()->{if(NativeCore.hasPending(session))NativeCore.delete(session);else removeText[0]=true;},true,()->{if(removeText[0])eraseCommitted();});}
 private void clearComposition(){
  PredictionSuppression.ClearPlan plan=predictions.clearComposition(pending(),queuedInputActions.get());int target=document;long lifetime=predictions.inputLifetime(),cancellation=predictions.cancellation();inputEpoch.incrementAndGet();if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);if(shownClipboardCandidate!=null)clipboardSuggestions.consume(document,shownClipboardCandidate.id);candidateItems.clear();shownClipboardCandidate=null;shownChoice=null;context=ContextWindow.EMPTY;syllables=new String[0];expanded=false;moreCandidates=false;loadingMore=false;nativeLoaded=0;snapshot=new String[][]{{"","","",""}};nativeSnapshot=new String[][]{{"","","","",""}};InputConnection connection=getCurrentInputConnection();updateMarkedText(connection);render();
  if(plan.invalidateOwnCommit){ownTracker.invalidate();replacement=null;ownContext="";}if(!plan.inspectNative){dismissedContinuationEpoch=inputEpoch.get();return;}dismissedContinuationEpoch=-1;queuedInputActions.incrementAndGet();
  InputActionDelivery.execute(worker,()->target==document&&predictions.active(lifetime),()->{if(session==0)return;boolean hadNative=NativeCore.hasPending(session);if(hadNative)NativeCore.clear(session);if(hadNative&&!plan.invalidateOwnCommit)main.post(()->{if(target==document&&predictions.active(lifetime)&&predictions.current(cancellation)){ownTracker.invalidate();replacement=null;ownContext="";}});},()->main.post(this::inputActionFinished));
 }
 private final ThreadLocal<android.graphics.Paint> glyphPaint=ThreadLocal.withInitial(()->{android.graphics.Paint paint=new android.graphics.Paint();paint.setTypeface(android.graphics.Typeface.DEFAULT);return paint;});
 private boolean candidateDisplayable(String text){return GlyphAvailability.displayable(text,point->glyphPaint.get().hasGlyph(new String(Character.toChars(point))));}
 private String[][] filterDisplayableRows(String[][] rows){if(rows.length==0)return rows;ArrayList<String[]> result=new ArrayList<>();result.add(rows[0]);for(int i=1;i<rows.length;i++)if(candidateDisplayable(rows[i][1]))result.add(rows[i]);return result.toArray(new String[0][]);}
 private void chooseClipboard(ClipboardCandidateState.Value offered,int target,long epoch){
  if(!ready||offered==null||target!=document||epoch!=inputEpoch.get()||pending()||predictions.suppressed()||!clipboardSuggestions.matches(target,offered.id))return;
  ClipboardCandidateState.Value current=ClipboardCandidateReader.read(this,getCurrentInputEditorInfo(),clipboardInputVisible);clipboardSuggestions.offer(document,current);
  if(current==null||!current.id.equals(offered.id)){render();return;}
  InputConnection connection=getCurrentInputConnection();if(connection==null)return;
  if(connection.commitText(current.raw,1)){
   clipboardSuggestions.consume(document,current.id);resumeSuggestionsForExplicitEdit();ownTracker.invalidate();ownContext="";replacement=null;shownChoice=null;context=ContextWindow.EMPTY;candidateItems.clear();expanded=false;marked=false;
   if(activityArchive!=null){activityArchive.layout(numbers?"numbers":symbols?"symbols":english?"english26":nine?"nine":"letters");activityArchive.systemClipboardCommitted(current.raw,true);}
   feedback(root);render();scheduleQuality();
  }
 }
 private void choose(int index,long token){if(index>0&&index<snapshot.length)chooseItem(new CandidateViews.Item(snapshot[index]),token);}
 private void chooseEnglish(CandidateViews.Item item,String prefix,int target,int start,int end){
  if(!english||numbers||symbols||secure||target!=document||selectionStart!=start||selectionEnd!=end||!preferences().getBoolean("english-completion",true)||!EnglishCompletion.allowed(getCurrentInputEditorInfo())||!EnglishCompletion.choices(mixedEnglish,prefix).contains(item.text))return;
  resumeSuggestionsForExplicitEdit();feedback(root);if(EnglishCompletion.select(getCurrentInputConnection(),prefix,item.text,start,end)){if(activityArchive!=null)activityArchive.revised(item.text);}else Toast.makeText(this,"当前输入框暂不支持替换此词",Toast.LENGTH_SHORT).show();render();
 }
 private void moveCursor(int delta){
  if(cursorDocument!=document||delta==0)return;int direction=delta<0?-1:1,count=Math.min(64,Math.abs(delta));
  if(cursorComposition){if(nine)return;submit(()->{for(int i=0;i<count;i++)NativeCore.moveCursor(session,direction);},false);}
  else{if(activityArchive!=null)activityArchive.uncertainEdit();InputConnection c=getCurrentInputConnection();if(c==null)return;for(int i=0;i<count;i++){int key=direction<0?KeyEvent.KEYCODE_DPAD_LEFT:KeyEvent.KEYCODE_DPAD_RIGHT;c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,key));c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,key));}}
 }
 private void chooseItem(CandidateViews.Item item,long token){if(!ready)return;resumeSuggestionsForExplicitEdit();feedback(root);submitLiteral(()->version==token?selectKnown(item):"",true,null);}
 private String enterLabel(){EditorInfo info=getCurrentInputEditorInfo();if(info==null)return "换行";switch(info.imeOptions&EditorInfo.IME_MASK_ACTION){case EditorInfo.IME_ACTION_SEND:return "发送";case EditorInfo.IME_ACTION_SEARCH:return "搜索";case EditorInfo.IME_ACTION_GO:return "前往";case EditorInfo.IME_ACTION_DONE:return "完成";case EditorInfo.IME_ACTION_NEXT:return "下一项";default:return "换行";}}
 private void editorAction(){InputConnection c=getCurrentInputConnection();if(c==null)return;EditorInfo info=getCurrentInputEditorInfo();int action=info==null?EditorInfo.IME_ACTION_NONE:info.imeOptions&EditorInfo.IME_MASK_ACTION;if(action!=EditorInfo.IME_ACTION_NONE&&action!=EditorInfo.IME_ACTION_UNSPECIFIED)c.performEditorAction(action);else{c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ENTER));c.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_ENTER));}}
 private void enter(){if(english||secure||numbers){editorAction();return;}boolean[] hadPending={false};submitLiteral(()->{hadPending[0]=NativeCore.hasPending(session);return hadPending[0]?acceptFirst():"";},true,()->{if(!hadPending[0])editorAction();});}
 private void finishSymbolCaret(InputConnection connection,int back){if(back<=0)return;ownTracker.invalidate();ownContext="";replacement=null;for(int i=0;i<Math.min(4,back);i++){connection.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_DPAD_LEFT));connection.sendKeyEvent(new KeyEvent(KeyEvent.ACTION_UP,KeyEvent.KEYCODE_DPAD_LEFT));}}
 private void insertSymbol(String symbol){resumeSuggestionsForExplicitEdit();if(!privateInput)catalog.record(symbol,preferences());SymbolPairing.Plan plan=SymbolPairing.plan(symbol,!secure&&preferences().getBoolean("symbol-auto-pair",true),preferences().getBoolean("symbol-caret-inside",true));if(english||secure||numbers){literal(plan.insertedText,plan.caretBack);return;}boolean[] inserted={false};submitLiteral(()->{String accepted=acceptFirst();inserted[0]=!NativeCore.hasPending(session);if(inserted[0]&&selectedIntent!=null)selectedIntent.suffix=plan.insertedText;return inserted[0]?accepted+plan.insertedText:accepted;},true,null,()->inserted[0]?plan.caretBack:0);}

 private final class KeyboardRoot extends LinearLayout {
  KeyboardRoot(Context context){super(context);}
  @Override public boolean dispatchTouchEvent(MotionEvent event){int phase=event.getActionMasked();if(phase==MotionEvent.ACTION_DOWN)renderGate.begin(header!=null&&event.getY()>=header.getTop()&&event.getY()<header.getBottom());else if(phase==MotionEvent.ACTION_POINTER_DOWN){float y=event.getY(event.getActionIndex());renderGate.pointerInHeader(header!=null&&y>=header.getTop()&&y<header.getBottom());}boolean handled=super.dispatchTouchEvent(event);if(phase==MotionEvent.ACTION_UP||phase==MotionEvent.ACTION_CANCEL){if(renderGate.end())post(LingheInputService.this::render);}return handled;}
  @Override protected void onDetachedFromWindow(){renderGate.end();super.onDetachedFromWindow();}
 }
 private LinearLayout row(){LinearLayout view=new LinearLayout(this);view.setOrientation(0);return view;}
 private Button button(String text,Runnable action){Button b=new KeyboardButton(this);b.setText(text);b.setTextSize(18);b.setTextColor(Ui.text(this));b.setAllCaps(false);b.setMinWidth(0);b.setMinimumWidth(0);b.setMinHeight(0);b.setMinimumHeight(0);b.setPadding(dp(2),0,dp(2),0);Ui.pressable(b,Ui.surface(this),6);int owner=document;((KeyboardButton)b).setKeyboardAction(()->{if(owner!=document)return;feedback(b);action.run();});return b;}
 private void utility(Button key){key.setTextSize(15);Ui.pressable(key,Ui.surface(this),6);}
 private void addKey(LinearLayout row,String text,float weight,Runnable action){Button key=button(text,action);if(text.equals("⇧"))utility(key);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,dp(keyHeight),weight);p.setMargins(dp(2),dp(2),dp(2),dp(2));row.addView(key,p);if(text.equals("空格"))new SpaceCursorGesture(key,()->{cursorDocument=document;ownTracker.invalidate();replacement=null;ownContext="";cursorComposition=pending()&&!english;inputEpoch.incrementAndGet();freezeCandidates();feedback(key);key.setAlpha(0.65f);},this::moveCursor,()->{cursorDocument=-1;key.setAlpha(1);});}
 private Button deleteButton(){Button key=button("⌫",this::erase);utility(key);key.setTextSize(23);key.setContentDescription("删除");key.setOnTouchListener((v,event)->{int action=event.getActionMasked();if(action==MotionEvent.ACTION_DOWN){key.setPressed(true);feedback(v);erase();repeating=new Runnable(){public void run(){erase();main.postDelayed(this,65);}};main.postDelayed(repeating,400);}else if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_CANCEL){key.setPressed(false);if(repeating!=null)main.removeCallbacks(repeating);repeating=null;}return true;});return key;}
 private void deleteKey(LinearLayout column){Button key=deleteButton();LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(keyHeight));p.setMargins(dp(2),dp(2),dp(2),dp(2));column.addView(key,p);}
 private void fixedKey(LinearLayout row,String text,int width,Runnable action){Button key=button(text,action);utility(key);LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(dp(width),dp(keyHeight));p.setMargins(dp(2),dp(2),dp(2),dp(2));row.addView(key,p);}
 private void menu(View anchor){PopupMenu menu=new PopupMenu(this,anchor);String[] choices={"中文九键","中文26键","矮","中","高"};for(String text:choices)menu.getMenu().add(text);menu.setOnMenuItemClickListener(item->{String value=item.getTitle().toString();if(value.startsWith("中文")){nine=value.equals("中文九键");english=false;preferences().edit().putBoolean("nine",nine).apply();configureEngine();}else{keyHeight=value.equals("矮")?46:value.equals("高")?68:58;preferences().edit().putInt("height",keyHeight).apply();render();}return true;});menu.show();}
 private int railWidth(){int available=root.getWidth()>0?root.getWidth()-root.getPaddingLeft()-root.getPaddingRight():getResources().getDisplayMetrics().widthPixels-dp(8);return CandidateViews.pinyinRailWidth(this,available);}
 private void rail(LinearLayout line){ScrollView scroll=new ScrollView(this);scroll.setVerticalScrollBarEnabled(false);scroll.setFillViewport(true);scroll.setBackground(Ui.shape(this,Ui.page(this),6));scroll.setClipToOutline(true);railStack=new LinearLayout(this);railStack.setOrientation(1);scroll.addView(railStack);line.addView(scroll,new LinearLayout.LayoutParams(railWidth(),-1));railSignature="";updateRail();}
 private void bindRail(KeyboardButton value,String text,int index,boolean filtering,boolean category,long token){
  value.setKeyboardAction(()->{feedback(value);if(category){symbolCategory=index;render();}else if(filtering){submit(()->{if(version!=token)return;String[] current=NativeCore.syllables(session);for(int j=0;j<current.length;j++)if(current[j].equals(text)){NativeCore.filter(session,j);break;}},false);}else insertSymbol(text);});
 }
 private void updateRail(){
  if(railStack==null)return;boolean filtering=pending()&&nine&&!english&&!numbers&&!symbols&&!secure&&syllables.length>0;String[] values;
  if(symbols)values=catalog.titles;else if(filtering)values=syllables;else{
   String railMode=numbers||english||secure?"numbers":"nine";if(!railMode.equals(symbolRailContext)||symbolRailSnapshot.length==0){if(numbers||english||secure)symbolRailSnapshot=catalog.rail(numericPunctuation,true,!privateInput&&!secure,preferences());else{LinkedHashSet<String> all=new LinkedHashSet<>();for(int i=0;i<4;i++)all.add(preferences().getString("rail"+i,punctuation[i]));all.addAll(Arrays.asList(punctuation));symbolRailSnapshot=catalog.rail(all.toArray(new String[0]),false,!privateInput&&!secure,preferences());}}values=symbolRailSnapshot;
  }
  symbolRailContext=symbols?"symbols":filtering?"pinyin":numbers||english||secure?"numbers":"nine";
  String signature=filtering+":"+symbols+":"+symbolCategory+Arrays.toString(values);long token=visibleVersion;
  if(signature.equals(railSignature)){for(int i=0;i<values.length;i++)bindRail((KeyboardButton)railStack.getChildAt(i),values[i],i,filtering,symbols,token);return;}
  railSignature=signature;railStack.removeAllViews();for(int i=0;i<values.length;i++){KeyboardButton value=(KeyboardButton)button(values[i],()->{});bindRail(value,values[i],i,filtering,symbols,token);value.opticalCenter=!filtering&&!symbols;value.setTextSize(filtering?15:symbols?13:20);if(filtering)CandidateViews.pinyinRailButton(value);value.setTextColor(symbols&&i==symbolCategory?Ui.accent(this):Ui.text(this));Ui.pressable(value,Color.TRANSPARENT,4);railStack.addView(value,new LinearLayout.LayoutParams(-1,dp(filtering||symbols?44:32)));}
 }

 private void render(){if(root==null)return;String shape=ready+":"+english+":"+nine+":"+numbers+":"+symbols+":"+symbolCategory+":"+expanded+":"+secure+":"+shift+":"+keyHeight+":"+dark()+":"+Ui.accentName(this)+(expanded?":"+visibleVersion:"");boolean rebuild=!shape.equals(builtLayout);if(renderGate.defer(rebuild))return;builtLayout=shape;
  if(rebuild){root.setBackgroundColor(Ui.rail(this));root.removeAllViews();compositionClearKeys.clear();railStack=null;candidateGrid=null;preeditText=new TextView(this);preeditText.setTextSize(14);preeditText.setTextColor(Ui.muted(this));preeditText.setPadding(dp(6),0,0,0);root.addView(preeditText,new LinearLayout.LayoutParams(-1,dp(22)));header=row();header.setBackgroundColor(Ui.page(this));root.addView(header,new LinearLayout.LayoutParams(-1,dp(48)));View division=new View(this);division.setBackgroundColor(Ui.rail(this));root.addView(division,new LinearLayout.LayoutParams(-1,dp(2)));}else header.removeAllViews();
  preeditText.setText(pending()&&!english&&!secure&&!preferences().getBoolean("inline",false)?visibleDraft():"");
  preeditText.setVisibility(preferences().getBoolean("inline",false)?View.GONE:View.VISIBLE);
  if(!ready){TextView loading=new TextView(this);loading.setText("正在准备词库…");header.addView(loading);}
  String englishPrefix=!predictions.suppressed()&&english&&!numbers&&!symbols&&!secure&&preferences().getBoolean("english-completion",true)&&EnglishCompletion.allowed(getCurrentInputEditorInfo())?EnglishCompletion.prefix(getCurrentInputConnection()):"";
  List<String> englishWords=EnglishCompletion.choices(mixedEnglish,englishPrefix);
  ClipboardCandidateState.Value clipboard=clipboardSuggestions.visible(document,ready&&!pending()&&!secure&&!symbols&&englishPrefix.isEmpty(),predictions.suppressed());shownClipboardCandidate=clipboard;
  ArrayList<CandidateViews.Item> presented=new ArrayList<>();if(clipboard!=null)presented.add(new CandidateViews.Item(new String[]{clipboard.id,clipboard.preview,""}));if(!english&&!secure)presented.addAll(candidateItems);
  auxiliaryCandidatesShown=!englishWords.isEmpty()||!presented.isEmpty();
  int clipboardDocument=document;long clipboardEpoch=inputEpoch.get();
  if(!englishWords.isEmpty()){int target=document,start=selectionStart,end=selectionEnd;ArrayList<CandidateViews.Item> values=new ArrayList<>();for(String word:englishWords)values.add(new CandidateViews.Item(new String[]{"completion:"+word,word,"英文"}));candidateStrip=new CandidateViews.Strip(this,item->chooseEnglish(item,englishPrefix,target,start,end),()->{},()->{});header.addView(candidateStrip,new LinearLayout.LayoutParams(0,-1,1));candidateStrip.update(values,true);}
  else if(!presented.isEmpty()){long token=visibleVersion;java.util.function.Consumer<CandidateViews.Item> choose=item->{if(clipboard!=null&&item.id.equals(clipboard.id))chooseClipboard(clipboard,clipboardDocument,clipboardEpoch);else chooseItem(item,token);};candidateStrip=new CandidateViews.Strip(this,choose,this::loadMore,this::freezeCandidates,(privateInput||recoveryPrivate)?null:(view,item)->manageCandidate(view,item,token));header.addView(candidateStrip,new LinearLayout.LayoutParams(0,-1,1));candidateStrip.update(presented,true);if(!candidateItems.isEmpty()&&!english&&!secure){Button expand=button(expanded?"⌃":"⌄",()->{freezeCandidates();expanded=!expanded;render();});expand.setOnTouchListener((view,event)->{if(event.getActionMasked()==MotionEvent.ACTION_DOWN)freezeCandidates();return false;});expand.setContentDescription(expanded?"收起候选":"展开候选");((KeyboardButton)expand).glyph=expanded?KeyboardButton.COLLAPSE:KeyboardButton.EXPAND;expand.setText("");Ui.pressable(expand,Color.TRANSPARENT,4);header.addView(expand,new LinearLayout.LayoutParams(dp(48),-1));}}
  else{candidateStrip=null;}
  header.setVisibility(View.VISIBLE);
  updateCompositionClear();if(!rebuild){if(candidateGrid!=null)candidateGrid.update(presented);updateRail();return;}
  if(expanded){long token=visibleVersion;candidateGrid=new CandidateViews.Expanded(this,item->{if(clipboard!=null&&item.id.equals(clipboard.id))chooseClipboard(clipboard,clipboardDocument,clipboardEpoch);else chooseItem(item,token);},this::loadMore,this::freezeCandidates,(privateInput||recoveryPrivate)?null:(view,item)->manageCandidate(view,item,token));root.addView(candidateGrid,new LinearLayout.LayoutParams(-1,dp(keyHeight*4+16)));candidateGrid.update(presented);return;}
  body=row();body.setBaselineAligned(false);root.addView(body,new LinearLayout.LayoutParams(-1,dp(keyHeight*3+12)));
  boolean letters=!numbers&&!symbols&&(english||!nine||secure);
  rail(body);LinearLayout center=new LinearLayout(this);center.setOrientation(1);center.setBaselineAligned(false);body.addView(center,new LinearLayout.LayoutParams(0,-1,1));
  if(letters){
   String[] rows={"qwertyuiop","asdfghjkl","zxcvbnm"};
   for(int r=0;r<3;r++){String text=rows[r];LinearLayout line=row();line.setBaselineAligned(false);center.addView(line);if(r==1)line.setPadding(dp(8),0,dp(8),0);if(r==2)addKey(line,"⇧",1.25f,()->{shift=!shift;render();});for(char c:text.toCharArray()){final char key=shift?Character.toUpperCase(c):c;addKey(line,String.valueOf(key),1,()->input(key));}if(r==2){View spacer=new View(this);line.addView(spacer,new LinearLayout.LayoutParams(0,1,1.25f));}}
  }else if(symbols){
   ScrollView scroll=new ScrollView(this);scroll.setVerticalScrollBarEnabled(false);GridLayout grid=new GridLayout(this);grid.setColumnCount(5);scroll.addView(grid);center.addView(scroll,new LinearLayout.LayoutParams(-1,-1));String[] values=catalog.page(symbolCategory,preferences());for(int i=0;i<values.length;i++){String text=values[i];Button symbol=button(text,()->insertSymbol(text));GridLayout.LayoutParams lp=new GridLayout.LayoutParams();lp.columnSpec=GridLayout.spec(i%5,1,1);lp.width=0;lp.height=dp(46);lp.setMargins(dp(2),dp(2),dp(2),dp(2));grid.addView(symbol,lp);}
  }else{
   String[] texts=numbers?new String[]{"1","2","3","4","5","6","7","8","9"}:new String[]{"分词","ABC","DEF","GHI","JKL","MNO","PQRS","TUV","WXYZ"};for(int r=0;r<3;r++){LinearLayout line=row();line.setBaselineAligned(false);center.addView(line);for(int c=0;c<3;c++){final int n=r*3+c;addKey(line,texts[n],1,()->input(numbers?'1'+n:n==0?'\'':'1'+n));}}
  }
  LinearLayout actions=new LinearLayout(this);actions.setOrientation(1);body.addView(actions,new LinearLayout.LayoutParams(dp(48),-1));deleteKey(actions);
  Button clear=button("清空",this::clearComposition);compositionClearKeys.add(clear);utility(clear);clear.setTextSize(11);LinearLayout.LayoutParams cp=new LinearLayout.LayoutParams(-1,dp(keyHeight));cp.setMargins(dp(2),dp(2),dp(2),dp(2));actions.addView(clear,cp);
  Button hide=button("",()->requestHideSelf(0));((KeyboardButton)hide).glyph=KeyboardButton.HIDE;utility(hide);hide.setContentDescription("收起键盘");LinearLayout.LayoutParams hp=new LinearLayout.LayoutParams(-1,dp(keyHeight));hp.setMargins(dp(2),dp(2),dp(2),dp(2));actions.addView(hide,hp);
  LinearLayout footer=row();footer.setBaselineAligned(false);root.addView(footer);fixedKey(footer,symbols?"返回":"符",44,()->{inputEpoch.incrementAndGet();symbols=!symbols;numbers=false;render();if(!symbols)scheduleQuality();});LinearLayout.LayoutParams leftKey=(LinearLayout.LayoutParams)footer.getChildAt(0).getLayoutParams();leftKey.width=railWidth()-dp(4);footer.getChildAt(0).setLayoutParams(leftKey);
  LinearLayout middle=row();middle.setBaselineAligned(false);footer.addView(middle,new LinearLayout.LayoutParams(0,-2,1));addKey(middle,numbers?"返回":"123",1,this::numeric);addKey(middle,numbers?"0":"空格",1,()->input(numbers?'0':' '));addKey(middle,english||secure?"英":"中",1,this::language);fixedKey(footer,enterLabel(),44,this::enter);updateCompositionClear();

 }
 @Override public void onUpdateSelection(int oldStart,int oldEnd,int newStart,int newEnd,int candidatesStart,int candidatesEnd){
  super.onUpdateSelection(oldStart,oldEnd,newStart,newEnd,candidatesStart,candidatesEnd);selectionStart=newStart;selectionEnd=newEnd;
  if((english||!pending())&&(oldStart!=newStart||oldEnd!=newEnd)) {
   inputEpoch.incrementAndGet();context=ContextWindow.EMPTY;browsing=false;candidateItems.clear();if(root!=null)render();scheduleQuality();
  }
 }
 @Override public void onFinishInput(){clipboardInputVisible=false;maintenance.visible(false,SystemClock.uptimeMillis());scheduleLearning();stopClipboardHeartbeat();clipboardSuggestions.offer(document,null);shownClipboardCandidate=null;AutoClipboardBridge.get(this).imeActive(false);if(activityArchive!=null){activityArchive.pause();activityArchive.flush();}document++;ownTracker.invalidate();replacement=null;ownContext="";shownChoice=null;inputEpoch.incrementAndGet();context=ContextWindow.EMPTY;if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);marked=false;if(repeating!=null)main.removeCallbacks(repeating);super.onFinishInput();if(ready&&!destroyed&&!worker.isShutdown())worker.execute(()->{NativeCore.clear(session);refreshRecentLearning();});}
 @Override public void onDestroy(){clipboardInputVisible=false;maintenance.visible(false,SystemClock.uptimeMillis());scheduleLearning();stopClipboardHeartbeat();if(clipboardCandidates!=null)clipboardCandidates.removePrimaryClipChangedListener(clipboardCandidateListener);clipboardSuggestions.offer(document,null);shownClipboardCandidate=null;AutoClipboardBridge.get(this).imeActive(false);if(activityArchive!=null)activityArchive.pause();if(PersonalReset.liveKeyboard==privacyReset)PersonalReset.liveKeyboard=null;destroyed=true;metadataRefresh.close();if(learningRefresh!=null)main.removeCallbacks(learningRefresh);if(personalReceiverRegistered){unregisterReceiver(personalReceiver);personalReceiverRegistered=false;}document++;inputEpoch.incrementAndGet();if(qualityRefresh!=null)main.removeCallbacks(qualityRefresh);if(repeating!=null)main.removeCallbacks(repeating);worker.execute(()->{if(session!=0)NativeCore.clear(session);refreshRecentLearning();NativeCore.destroy(session);session=0;recentIO.execute(recentIO::shutdown);});worker.shutdown();super.onDestroy();}
}
