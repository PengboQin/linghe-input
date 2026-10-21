package live.linghe.privateinput;
import android.app.*;
import android.os.*;
import android.content.*;
import android.text.InputType;
import android.view.*;
import android.widget.*;

/** Native opt-in controls; no document text, keys or credential content is shown. */
public final class ActivityArchiveActivity extends Activity {
  private ActivityArchiveManager archive;private LinearLayout body;private EditText endpoint;
  private Switch relay,input,clips,readers;private TextView status;private boolean busy;
  private final Handler main=new Handler(Looper.getMainLooper());
  private final Runnable refresh=()->{if(status!=null)status.setText(archive.health());if(!isFinishing())main.postDelayed(this.refresh,2000);};
  private int dp(float value){return Ui.dp(this,value);}
  private TextView label(String value,int size){TextView view=new TextView(this);view.setText(value);view.setTextColor(Ui.text(this));view.setTextSize(size);view.setPadding(0,dp(8),0,dp(8));return view;}
  private Button button(String text,Runnable action){Button view=new Button(this);view.setText(text);view.setTextColor(Ui.accent(this));view.setAllCaps(false);Ui.pressable(view,Ui.surface(this),10);view.setOnClickListener(v->{if(!busy)action.run();});LinearLayout.LayoutParams size=new LinearLayout.LayoutParams(-1,dp(50));size.topMargin=dp(8);body.addView(view,size);return view;}
  private Switch toggle(String text,boolean selected){Switch view=new Switch(this);view.setText(text);view.setTextColor(Ui.text(this));view.setTextSize(16);view.setChecked(selected);body.addView(view,new LinearLayout.LayoutParams(-1,dp(54)));return view;}
  @Override public void onCreate(Bundle saved){
    Ui.prepareTheme(this);super.onCreate(saved);archive=ActivityArchiveManager.get(this);ScrollView scroll=new ScrollView(this);scroll.setBackgroundColor(Ui.page(this));body=new LinearLayout(this);body.setOrientation(1);body.setPadding(dp(20),dp(16),dp(20),dp(28));scroll.addView(body);setContentView(scroll);
    scroll.setOnApplyWindowInsetsListener((view,insets)->{body.setPadding(dp(20)+insets.getSystemWindowInsetLeft(),dp(16)+insets.getSystemWindowInsetTop(),dp(20)+insets.getSystemWindowInsetRight(),dp(28)+insets.getSystemWindowInsetBottom());return insets;});
    button("返回",this::finish);body.addView(label("活动归档",26));status=label(archive.health(),14);status.setTextColor(Ui.muted(this));body.addView(status);
    TextView notice=label("开启后，输入法确认输出和所选剪贴板文字会以完整明文保存在服务器。服务器管理员可读取正文。词库与共享文本的端到端加密设置不受影响。",15);body.addView(notice);
    relay=toggle("使用当前设备组的同步服务器",archive.useRelay());endpoint=new EditText(this);endpoint.setSingleLine();endpoint.setHint("https://sync.example.invalid");endpoint.setTextColor(Ui.text(this));endpoint.setTextSize(16);endpoint.setInputType(InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_URI);endpoint.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);endpoint.setText(archive.endpoint());endpoint.setVisibility(relay.isChecked()?View.GONE:View.VISIBLE);body.addView(endpoint,new LinearLayout.LayoutParams(-1,dp(54)));relay.setOnCheckedChangeListener((v,on)->endpoint.setVisibility(on?View.GONE:View.VISIBLE));
    input=toggle("归档本输入法确认输出",archive.inputEnabled());clips=toggle("归档系统允许读取的剪贴板文字",archive.clipboardEnabled());readers=toggle("允许当前在组设备读取我的归档",archive.shareReaders());
    body.addView(label("新加入设备不会自动取得历史阅读授权。密码、安全或未知输入框不记录；Android 后台与剪贴板限制可能造成缺口。",13));
    button("保存并开启本机归档",()->{
      if(!input.isChecked()&&!clips.isChecked()){archive.pause();status.setText(archive.health());return;}
      Ui.dialog(new AlertDialog.Builder(this).setTitle("确认服务器保存完整正文")
        .setMessage("本设备所选来源的完整文字将上传到你指定的服务器，并按设备组保存。"+(readers.isChecked()?"当前在组设备将获准读取本设备归档。":"默认只允许本设备读取归档。")+"暂停后旧授权待发在本机暂存，不会自动转入新的授权补传；你可以独立清除本机队列。服务器已有记录按其保留政策保存，需另行删除。")
        .setNegativeButton("取消",null).setPositiveButton("同意并开启",(d,w)->{busy=true;status.setText("正在核对设备组和归档授权…");archive.configure(endpoint.getText().toString(),relay.isChecked(),input.isChecked(),clips.isChecked(),readers.isChecked(),this::completed);}).create());
    });
    button("立即上传 / 重试",archive::retry);Button pause=button("暂停归档",()->{});pause.setOnClickListener(v->{busy=false;archive.pause();input.setChecked(false);clips.setChecked(false);status.setText(archive.health());});
    input.setOnCheckedChangeListener((view,on)->{if(!on&&archive.inputEnabled()){archive.pause();status.setText(archive.health());}});clips.setOnCheckedChangeListener((view,on)->{if(!on&&archive.clipboardEnabled()){archive.pause();status.setText(archive.health());}});
    button("清除本机待发与暂存",()->Ui.dialog(new AlertDialog.Builder(this).setTitle("清除本机归档队列？").setMessage("这会暂停采集并删除尚未上传和旧授权暂存的本机明文；不会删除服务器已有记录。此操作无法撤销。").setNegativeButton("取消",null).setPositiveButton("清除",(d,w)->{busy=false;archive.clearLocal();input.setChecked(false);clips.setChecked(false);}).create()));
    button("设备组归档设置",()->Ui.dialog(new AlertDialog.Builder(this).setTitle("组归档")
      .setMessage("仅完整授权成员可调整。开启组功能后，每台设备仍需自行同意。首次默认保留 30 天、组容量 100 MiB；已有配置将保留。")
      .setNegativeButton("取消",null).setNeutralButton("关闭组归档",(d,w)->setGroup(false)).setPositiveButton("开启组归档",(d,w)->setGroup(true)).create()));
  }
  private void setGroup(boolean on){busy=true;status.setText("正在更新组归档设置…");archive.groupPolicy(endpoint.getText().toString(),relay.isChecked(),on,this::completed);}
  private void completed(String error){busy=false;if(isFinishing()||isDestroyed())return;status.setText(error==null?archive.health():error);if(error!=null)Toast.makeText(this,error,Toast.LENGTH_LONG).show();}
  @Override public void onResume(){super.onResume();main.post(refresh);}
  @Override public void onPause(){main.removeCallbacks(refresh);super.onPause();}
}
