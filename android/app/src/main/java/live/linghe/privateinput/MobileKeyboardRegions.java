package live.linghe.privateinput;

/** Pixel budgets used by both collapsed and expanded keyboard views. */
final class MobileKeyboardRegions {
 static final int ACTION_DP=48,SYMBOL_ROW_DP=48,SYMBOL_GRID_DP=48;
 static int rowPitch(int keyHeight,int margin){return keyHeight+2*margin;}
 static int bodyHeight(int keyHeight,int margin){return 3*rowPitch(keyHeight,margin);}
 static int totalKeysHeight(int keyHeight,int margin){return 4*rowPitch(keyHeight,margin);}
 static int insetKeyWidth(int outerWidth,int margin){return Math.max(1,outerWidth-2*margin);}
 static int symbolColumns(int availableWidth,int minimumKeyWidth,int margin){return Math.max(3,Math.min(5,availableWidth/Math.max(1,minimumKeyWidth+2*margin)));}
 static float inkOrigin(int extent,int start,int end){return (extent-start-end)/2f;}
 static int actionLeft(int bodyWidth,int actionWidth){return Math.max(0,bodyWidth-actionWidth);}
 static int centerWidth(int bodyWidth,int railWidth,int actionWidth){return Math.max(0,bodyWidth-railWidth-actionWidth);}
 static int expandedWidth(int bodyWidth,int actionWidth){return Math.max(0,bodyWidth-actionWidth);}
}
