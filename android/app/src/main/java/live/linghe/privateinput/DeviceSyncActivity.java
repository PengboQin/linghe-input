package live.linghe.privateinput;
import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.*;
import android.view.*;
import android.widget.*;
import android.text.InputType;
import org.json.*;
import java.util.*;
public final class DeviceSyncActivity extends Activity {
  private LinearLayout body,details,inbox;
  private TextView status;
  private EditText endpoint,code,message;
  private Switch learn,shared;
  private boolean active=false,changing=false;
  private String lastError="";
  private final Handler main=new Handler(Looper.getMainLooper());
  private final Runnable poll=()->run(false,c->{
    return null;
  }
  );
  interface Work {
    Object run(SyncClient client)throws Exception;
  }
  private int dp(float n){
    return Ui.dp(this,n);
  }
  private TextView label(String s,int size){
    TextView t=new TextView(this);
    t.setText(s);
    t.setTextSize(size);
    t.setTextColor(Ui.text(this));
    return t;
  }
  private void button(LinearLayout box,String title,Runnable action){
    Button b=new Button(this);
    b.setAllCaps(false);
    b.setText(title);
    b.setTextColor(Ui.accent(this));
    Ui.pressable(b,Ui.surface(this),10);
    b.setOnClickListener(v->action.run());
    LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(50));
    p.setMargins(0,dp(5),0,dp(5));
    box.addView(b,p);
  }
  private EditText editor(String hint,int input){
    EditText e=new ActivityArchiveEditText(this);
    e.setTextColor(Ui.text(this));
    e.setTextSize(17);
    e.setHint(hint);
    e.setInputType(input);
    e.setPadding(dp(12),dp(10),dp(12),dp(10));
    return e;
  }
  @Override public void onCreate(Bundle saved){
    Ui.prepareTheme(this);super.onCreate(saved);
    ScrollView scroll=new ScrollView(this);
    scroll.setBackgroundColor(Ui.page(this));
    body=new LinearLayout(this);
    body.setOrientation(1);
    body.setPadding(dp(20),dp(20),dp(20),dp(28));
    scroll.addView(body);
    setContentView(scroll);
    scroll.setOnApplyWindowInsetsListener((v,i)->{
      body.setPadding(dp(20)+i.getSystemWindowInsetLeft(),dp(16)+i.getSystemWindowInsetTop(),dp(20)+i.getSystemWindowInsetRight(),dp(24)+i.getSystemWindowInsetBottom());return i;
    }
    );
    button(body,"返回",this::finish);
    body.addView(label("设备与同步",26));
    status=label("",14);
    body.addView(status);
    details=new LinearLayout(this);
    details.setOrientation(1);
    body.addView(details);
    inbox=new LinearLayout(this);
    inbox.setOrientation(1);
    body.addView(inbox);
    refresh();
  }
  private void run(boolean manual,Work work){
    if(manual)status.setText("正在处理…");
    SyncTasks.worker.execute(()->{
      String error=null;Object result=null;try{
        SyncClient c=new SyncClient(this);result=work.run(c);
      }
      catch(Exception e){
        error=e instanceof java.security.GeneralSecurityException?"此设备暂时无法使用同步加密，原资料已保留":e.getMessage();if(error==null)error="同步暂时失败，请重试";
      }
      String failure=error;Object output=result;main.post(()->{
        if(isFinishing()||isDestroyed())return;lastError=failure==null?"":failure;if(manual&&failure!=null)Toast.makeText(this,failure,Toast.LENGTH_LONG).show();if(output instanceof JSONObject){
          JSONObject value=(JSONObject)output;if(value.has("deviceList"))showDevices(value);else showTicket(value);
        }
        refresh();
      }
      );
    }
    );
  }
  private void refresh(){
    SyncTasks.worker.execute(()->{
      try{
        SyncClient c=new SyncClient(this);boolean connected=c.connected(),joining=c.joining(),expired=c.joiningExpired();long deadline=c.joiningDeadline();String departed=c.departureReason();String server=c.endpoint();int count=c.members();boolean l=c.learning(),s=c.clipboard();JSONArray messages=c.inbox(),unsent=c.unsent();JSONObject ticket=c.ticket();boolean inviting=ticket!=null&&ticket.optLong("expiresAt",0)>System.currentTimeMillis()/1000;main.post(()->{
          if(isFinishing()||isDestroyed())return;status.setText(connected?count+" 台设备 · "+(l||s?"端到端加密":"同步已暂停"):joining?(expired?"连接已超时，请重新扫码或输入新码":"等待邀请设备完成连接"):(departed.isEmpty()?"尚未连接设备组":"已离组，本机个人资料已清除"));if(!lastError.isEmpty())status.append("\n"+lastError);else if(!LingheApplication.syncError.isEmpty())status.append("\n"+LingheApplication.syncError);String shape=connected+":"+joining+":"+expired;if(!shape.equals(details.getTag())){
            details.setTag(shape);render(c,connected,joining,server,l,s);
          }
          renderInbox(messages,unsent,s);main.removeCallbacks(poll);if(active&&(connected||joining&&!expired))main.postDelayed(poll,joining||inviting?3000:15000);
        }
        );
      }
      catch(Exception e){
        main.post(()->status.setText("同步资料暂不可用，原文件已保留"));
      }
    }
    );
  }
  private void render(SyncClient c,boolean connected,boolean joining,String server,boolean l,boolean s){
    details.removeAllViews();
    if(!connected&&joining){
      boolean expired=c.joiningExpired();
      details.addView(label(expired?"请在邀请设备重新生成接入码，然后重新扫码或输入新码。":"只需生成邀请的设备在线，其他设备可以离线。",15));
      if(!expired){details.addView(label("请求截止 "+java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(new Date(c.joiningDeadline()*1000)),13));button(details,"立即重试",()->run(true,x->{x.synchronize();return null;}));}
      button(details,expired?"重新接入":"取消接入",()->run(true,x->{x.cancelJoining();return null;}));return;
    }
    if(!connected){
      endpoint=editor("HTTPS 同步服务器",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);
      endpoint.setText(server.isEmpty()?SyncBuildConfig.DEFAULT_ENDPOINT:server);
      details.addView(endpoint);
      code=editor("六位接入码",InputType.TYPE_CLASS_NUMBER);
      code.setFilters(new android.text.InputFilter[]{
        new android.text.InputFilter.LengthFilter(6)
      }
      );
      details.addView(code);
      button(details,joining?"重试接入":"加入设备组",()->run(true,x->{
        x.join(code.getText().toString().trim(),endpoint.getText().toString());x.synchronize();return null;
      }
      ));
      button(details,"扫描已接入设备的二维码",()->startActivityForResult(new Intent(this,QRScanActivity.class),17002));
      if(joining)button(details,"取消接入",()->run(true,x->{
        x.cancelJoining();return null;
      }
      ));
      if(!joining)button(details,"创建独立设备组",()->run(true,x->{
        x.createGroup(endpoint.getText().toString());return null;
      }
      ));
      details.addView(label("扫码自动读取服务器；手动输入接入码时需同时填写服务器。邀请仅限一台设备使用，5分钟后失效。",13));
      return;
    }
    learn=new Switch(this);
    learn.setText("输入习惯与个人词库");
    learn.setTextColor(Ui.text(this));
    learn.setChecked(l);
    details.addView(learn,new LinearLayout.LayoutParams(-1,dp(54)));
    shared=new Switch(this);
    shared.setText("共享文本");
    shared.setTextColor(Ui.text(this));
    shared.setChecked(s);
    details.addView(shared,new LinearLayout.LayoutParams(-1,dp(54)));
    android.widget.CompoundButton.OnCheckedChangeListener toggle=(v,on)->{
      if(changing)return;
      boolean a=learn.isChecked(),b=shared.isChecked();
      synchronized(SyncClient.CONSENT_LOCK){
        getSharedPreferences("sync-consent",0).edit().putLong("generation",getSharedPreferences("sync-consent",0).getLong("generation",0)+1).putBoolean("learning",a).putBoolean("clipboard",b).commit();
      }
      SyncJob.schedule(this);
      run(false,x->{
        x.synchronize();return null;
      }
      );
    }
    ;
    learn.setOnCheckedChangeListener(toggle);
    shared.setOnCheckedChangeListener(toggle);
    Switch automatic=new Switch(this);automatic.setText("自动同步系统剪贴板");automatic.setTextColor(Ui.text(this));automatic.setChecked(AutoClipboardBridge.get(this).enabled());automatic.setEnabled(s);
    details.addView(automatic,new LinearLayout.LayoutParams(-1,dp(54)));
    automatic.setOnCheckedChangeListener((button,on)->{if(!changing){AutoClipboardBridge.get(this).setEnabled(on);SyncJob.schedule(this);run(false,x->{x.synchronize();return null;});}});
    shared.setOnCheckedChangeListener((button,on)->{toggle.onCheckedChanged(button,on);automatic.setEnabled(on);});
    button(details,"立即同步",()->run(true,x->{
      x.synchronize();return null;
    }
    ));
    button(details,"添加设备",()->run(true,SyncClient::invite));
    button(details,"在组设备",()->run(true,x->new JSONObject().put("deviceList",x.devices())));
    button(details,"闲置自动离组期限",()->{
      EditText days=editor("1–90 天，默认 30 天",InputType.TYPE_CLASS_NUMBER);days.setText("30");
      new AlertDialog.Builder(this).setTitle("未连接多少天后离组").setView(days).setMessage("离组后清除本机个人词库和共享资料，最长 90 天。").setNegativeButton("取消",null).setPositiveButton("保存",(d,w)->run(true,x->{int n;try{n=Integer.parseInt(days.getText().toString());}catch(Exception e){throw new java.io.IOException("请输入 1–90 天");}if(n<1||n>90)throw new java.io.IOException("请输入 1–90 天");x.setIdleDays(n);return null;})).show();
    });
    button(details,"退出设备组",()->new AlertDialog.Builder(this).setTitle("退出并清除本机资料？").setMessage("个人词库、学习记录、快捷短语和共享文本将恢复初装状态。此操作无法撤销。").setNegativeButton("取消",null).setPositiveButton("退出并清除",(d,w)->run(true,x->{x.leaveGroup();return null;})).show());
    details.addView(label("仅同步已开启的项目。打字在本机处理；系统可能延迟后台同步。",13));
    message=editor("发送共享文本",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_MULTI_LINE);((ActivityArchiveEditText)message).archivePaste=true;
    details.addView(message);
    button(details,"发送",()->{
      String text=message.getText().toString();run(true,x->{
        x.sendText(text);main.post(()->message.setText(""));return null;
      }
      );
    }
    );
    button(details,"暂停此设备同步",()->new AlertDialog.Builder(this).setTitle("暂停此设备同步？").setMessage("关闭两个同步开关，保留配对和本机词库。之后可随时恢复。").setNegativeButton("取消",null).setPositiveButton("暂停",(d,w)->run(true,x->{
      x.disconnect();SyncJob.schedule(this);return null;
    }
    )).show());
  }
  private String inboxSignature="";
  private void renderInbox(JSONArray items,JSONArray unsent,boolean enabled){
    String signature=enabled+":"+items.toString()+":"+unsent.toString();
    if(signature.equals(inboxSignature))return;
    inboxSignature=signature;
    inbox.removeAllViews();
    if(!enabled)return;
    if(unsent.length()>0){
      inbox.addView(label("待确认发送",18));
      inbox.addView(label("设备组变化前的发送结果未确认。",13));
      for(int n=0;n<unsent.length();n++){
        JSONObject row=unsent.optJSONObject(n);
        String event=row.optString("event");
        inbox.addView(new SharedTextEntry(this,row.optString("text"),"重新发送",raw->run(true,c->{
          c.resend(event);return null;
        })));
      }
    }
    inbox.addView(label("收到的共享文本",18));
    for(int i=items.length()-1;i>=0;i--){
      JSONObject item=items.optJSONObject(i);
      String text=item.optString("text");
      inbox.addView(new SharedTextEntry(this,text,"复制",raw->{
        ClipData clip=ClipData.newPlainText("共享文本",raw);AutoClipboardBridge.get(this).markOwn(clip,item.optString("event",item.optString("id","")));ActivityArchiveManager.get(this).ownClipboard(clip,item.optString("event",item.optString("id","")));((android.content.ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(clip);Toast.makeText(this,"已复制",Toast.LENGTH_SHORT).show();
      }));
    }
  }
  private void showTicket(JSONObject value){
    try{
      String link=value.getString("link"),code=value.getString("code");
      LinearLayout content=new LinearLayout(this);
      content.setOrientation(1);
      content.setGravity(Gravity.CENTER);
      content.setPadding(dp(18),dp(12),dp(18),dp(12));
      TextView number=label(code,34);
      number.setTextIsSelectable(true);
      content.addView(number);
      com.google.zxing.common.BitMatrix matrix=new com.google.zxing.qrcode.QRCodeWriter().encode(link,com.google.zxing.BarcodeFormat.QR_CODE,640,640);
      Bitmap image=Bitmap.createBitmap(640,640,Bitmap.Config.ARGB_8888);
      for(int y=0;y<640;y++)for(int x=0;x<640;x++)image.setPixel(x,y,matrix.get(x,y)?Color.BLACK:Color.WHITE);
      ImageView qr=new ImageView(this);
      qr.setImageBitmap(image);
      content.addView(qr,new LinearLayout.LayoutParams(dp(240),dp(240)));
      content.addView(label("5分钟内有效，由新设备在App内扫码或输入接入码。",13));
      AlertDialog dialog=new AlertDialog.Builder(this).setTitle("添加设备").setView(content).setPositiveButton("关闭邀请",(d,w)->run(false,x->{
        x.closeTicket();return null;
      }
      )).create();
      dialog.setOnCancelListener(d->run(false,x->{
        x.closeTicket();return null;
      }
      ));
      Ui.dialog(dialog);
    }
    catch(Exception error){
      Toast.makeText(this,"接入码已生成，二维码暂不可显示",Toast.LENGTH_SHORT).show();
    }
  }
  private void showDevices(JSONObject result){
    try{
      JSONArray values=result.getJSONArray("deviceList");
      String[] labels=new String[values.length()];
      for(int i=0;i<values.length();i++){
        JSONObject value=values.getJSONObject(i);
        String kind=value.optString("kind");String title=kind.equals("ios")?"iPhone / iPad":kind.equals("android")?"Android 手机":kind.equals("macos")?"Mac":kind.equals("windows")?"Windows 电脑":"待更新的设备";
        labels[i]=title+(value.optBoolean("isSelf")?" · 本机":" · "+value.getString("device").substring(0,6))+"\n"+(value.optBoolean("inactive")?"已过期":value.optLong("lastSeen")==0?"等待更新信息":"最近连接 "+java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.SHORT,java.text.DateFormat.SHORT).format(new Date(value.optLong("lastSeen")*1000)));
      }
      new AlertDialog.Builder(this).setTitle("设备").setItems(labels,(d,index)->{
        JSONObject value=values.optJSONObject(index);if(value.optBoolean("isSelf"))return;
        String kind=value.optString("kind");if(!kind.equals("macos")&&!kind.equals("windows")){Toast.makeText(this,"手机不能移除其他手机或尚未确认类型的设备",Toast.LENGTH_LONG).show();return;}
        String id=value.optString("device");new AlertDialog.Builder(this).setTitle("移除此设备？").setMessage("移除后轮换组密钥。该设备联网获知离组后会清除个人词库、学习记录和共享资料。").setNegativeButton("取消",null).setPositiveButton("移除",(dialog,which)->run(true,c->{
          c.revoke(id);return null;
        }
        )).show();
      }
      ).setNegativeButton("关闭",null).show();
    }
    catch(Exception invalid){
      Toast.makeText(this,"设备列表暂不可用",Toast.LENGTH_SHORT).show();
    }
  }
  @Override protected void onActivityResult(int request,int result,Intent data){
    super.onActivityResult(request,result,data);
    if(request==17002&&result==RESULT_OK&&data!=null){
      String link=data.getStringExtra("qr");
      run(true,c->{
        c.joinQR(link);c.synchronize();return null;
      }
      );
    }
  }
  @Override protected void onResume(){
    super.onResume();
    active=true;
    refresh();
  }
  @Override protected void onPause(){
    active=false;
    main.removeCallbacks(poll);
    super.onPause();
  }
}
