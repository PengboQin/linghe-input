package live.linghe.privateinput;
import android.app.Activity;import android.os.Bundle;import android.view.WindowManager;import android.widget.TextView;
/** Visible, non-editable synthetic test host; no clipboard or keyboard input. */
public final class SyncAcceptanceActivity extends Activity {
 @Override public void onCreate(Bundle state){super.onCreate(state);getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);TextView text=new TextView(this);text.setText("灵鹤同步隔离验证\n仅使用合成设备组与测试资料");text.setTextSize(21);text.setPadding(40,120,40,40);setContentView(text);}
}
