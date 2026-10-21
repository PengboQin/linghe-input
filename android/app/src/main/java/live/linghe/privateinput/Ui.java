package live.linghe.privateinput;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.*;
import android.view.View;

final class Ui {
 static String mode(Context c){return c.getSharedPreferences("keyboard",0).getString("appearance-mode","system");}
 static String accentName(Context c){return c.getSharedPreferences("keyboard",0).getString("appearance-accent","rose");}
 static boolean dark(Context c){return InputTheme.dark(mode(c),(c.getResources().getConfiguration().uiMode&48)==32);}
 static int themeId(Context c){return c.getResources().getIdentifier("AppTheme_"+(dark(c)?"dark":"light")+"_"+InputTheme.ACCENTS[InputTheme.index(InputTheme.ACCENTS,accentName(c))],"style",c.getPackageName());}
 // Initial IME theme must be selected before InputMethodService.onCreate().
 static void prepareTheme(Context c){int id=themeId(c);if(id!=0)c.setTheme(id);}
 // A live InputMethodService forbids setTheme(); refresh native widget attributes in place.
 static void refreshTheme(Context c){int id=themeId(c);if(id!=0)c.getTheme().applyStyle(id,true);}
 static int dp(Context c,float n){return Math.round(n*c.getResources().getDisplayMetrics().density);}
 static int text(Context c){return InputTheme.text(dark(c));}
 static int muted(Context c){return InputTheme.secondary(dark(c));}
 static int page(Context c){return InputTheme.background(dark(c));}
 static int surface(Context c){return InputTheme.key(dark(c));}
 static int accent(Context c){return InputTheme.accent(accentName(c),dark(c));}
 static int rail(Context c){return InputTheme.rail(dark(c));}
 static GradientDrawable shape(Context c,int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(c,radius));return d;}
 static void dialog(android.app.AlertDialog d){d.show();if(d.getWindow()!=null){d.getWindow().setBackgroundDrawable(shape(d.getContext(),surface(d.getContext()),16));d.getWindow().getDecorView().setClipToOutline(true);}}
 static void panel(View view){view.setBackground(shape(view.getContext(),surface(view.getContext()),14));}
 static void pressable(View view,int color,int radius){Context c=view.getContext();StateListDrawable d=new StateListDrawable();d.addState(new int[]{android.R.attr.state_pressed},shape(c,InputTheme.selection(accentName(c),dark(c)),radius));d.addState(new int[]{},shape(c,color,radius));view.setBackground(d);view.setElevation(0);view.setStateListAnimator(null);}
}
