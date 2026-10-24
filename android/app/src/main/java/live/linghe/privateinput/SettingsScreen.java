package live.linghe.privateinput;

import android.app.Activity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Toolbar;

/** Common native app-page chrome; no preferences, permissions or sync work. */
final class SettingsScreen {
 static Object interceptBack(Activity activity,Runnable action){return android.os.Build.VERSION.SDK_INT>=33?Api33.register(activity,action):null;}
 static void releaseBack(Activity activity,Object callback){if(callback!=null&&android.os.Build.VERSION.SDK_INT>=33)Api33.unregister(activity,callback);}
 private static final class Api33 {
  static Object register(Activity activity,Runnable action){android.window.OnBackInvokedCallback callback=action::run;activity.getOnBackInvokedDispatcher().registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,callback);return callback;}
  static void unregister(Activity activity,Object callback){activity.getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback((android.window.OnBackInvokedCallback)callback);}
 }
 static LinearLayout content(Activity activity,String title,boolean up){return content(activity,title,up,true);}
 static LinearLayout content(Activity activity,String title,boolean up,boolean scrolling){
  LinearLayout shell=new LinearLayout(activity);shell.setOrientation(LinearLayout.VERTICAL);shell.setBackgroundColor(Ui.page(activity));
  Toolbar bar=new Toolbar(activity);bar.setTitleTextColor(Ui.text(activity));bar.setSubtitleTextColor(Ui.muted(activity));bar.setBackgroundColor(Ui.page(activity));bar.setTitle(title);
  shell.addView(bar,new LinearLayout.LayoutParams(-1,Ui.dp(activity,56)));activity.setActionBar(bar);
  if(activity.getActionBar()!=null){activity.getActionBar().setTitle(title);activity.getActionBar().setDisplayHomeAsUpEnabled(up);activity.getActionBar().setHomeActionContentDescription("返回");}
  LinearLayout body=new LinearLayout(activity);body.setOrientation(LinearLayout.VERTICAL);body.setPadding(Ui.dp(activity,20),Ui.dp(activity,8),Ui.dp(activity,20),Ui.dp(activity,24));
  if(scrolling){ScrollView scroll=new ScrollView(activity);scroll.setFillViewport(true);scroll.setVerticalScrollBarEnabled(false);scroll.addView(body,new ScrollView.LayoutParams(-1,-2));shell.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));}
  else shell.addView(body,new LinearLayout.LayoutParams(-1,0,1));
  activity.setContentView(shell);
  shell.setOnApplyWindowInsetsListener((view,insets)->{shell.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;});
  activity.getWindow().setStatusBarColor(Ui.page(activity));activity.getWindow().setNavigationBarColor(Ui.page(activity));activity.getWindow().getDecorView().setSystemUiVisibility(Ui.dark(activity)?0:View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR|View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
  return body;
 }
 private SettingsScreen(){}
}
