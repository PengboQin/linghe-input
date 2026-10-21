package live.linghe.privateinput;
import android.content.Context;
import android.graphics.Color;
import android.view.Gravity;
import android.widget.*;
import java.util.function.Consumer;
/** Native multiline text; the action always receives the original payload. */
final class SharedTextEntry extends LinearLayout {
 SharedTextEntry(Context context,String raw,String action,Consumer<String> accept){
  super(context);setOrientation(VERTICAL);setPadding(0,Ui.dp(context,8),0,Ui.dp(context,8));
  TextView body=new TextView(context);body.setText(raw);body.setTextSize(16);body.setTextColor(Ui.text(context));body.setTextIsSelectable(true);body.setPadding(0,0,0,Ui.dp(context,4));addView(body,new LayoutParams(-1,-2));
  Button button=new Button(context);button.setText(action);button.setAllCaps(false);button.setTextColor(Ui.accent(context));button.setMinWidth(0);button.setMinimumWidth(0);button.setMinHeight(Ui.dp(context,44));button.setMinimumHeight(Ui.dp(context,44));Ui.pressable(button,Color.TRANSPARENT,8);button.setOnClickListener(view->accept.accept(raw));LayoutParams p=new LayoutParams(-2,Ui.dp(context,44));p.gravity=Gravity.END;addView(button,p);
 }
}
