package live.linghe.privateinput;

import android.content.Context;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import java.util.function.Function;
import java.util.function.Supplier;

/** The iOS mobile letter geometry: 10 / 9 / 7, half-key second-row offsets,
 * Shift and Delete in the last row, no independent left or right utility rails. */
final class EnglishKeyboardRows {
 static boolean fullWidth(boolean english,boolean secure,boolean numbers,boolean symbols){return (english||secure)&&!numbers&&!symbols;}
 private static final String[] ROWS={"qwertyuiop","asdfghjkl","zxcvbnm"};
 static String letters(int row){return ROWS[row];}
 static float outerWeight(int row){return row==1?0.5f:row==2?1.5f:0;}
 static void populate(LinearLayout area,int height,boolean upper,Function<Character,Button> letter,Supplier<Button> shift,Supplier<Button> delete){
  Context c=area.getContext();
  for(int index=0;index<ROWS.length;index++){
   LinearLayout row=new LinearLayout(c);row.setBaselineAligned(false);area.addView(row);
   if(index==1)spacer(row,outerWeight(index));
   if(index==2)add(row,shift.get(),height,outerWeight(index));
   for(char value:letters(index).toCharArray())add(row,letter.apply(upper?Character.toUpperCase(value):value),height,1);
   if(index==1)spacer(row,outerWeight(index));
   if(index==2)add(row,delete.get(),height,outerWeight(index));
  }
 }
 private static void spacer(LinearLayout row,float weight){View v=new View(row.getContext());v.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);row.addView(v,new LinearLayout.LayoutParams(0,1,weight));}
 private static void add(LinearLayout row,Button key,int height,float weight){LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,Ui.dp(row.getContext(),height),weight);int margin=Ui.dp(row.getContext(),2);p.setMargins(margin,margin,margin,margin);row.addView(key,p);}
}
