package live.linghe.privateinput;
/** Same local appearance choices and RGB values as Apple InputTheme; no green option. */
final class InputTheme {
 static final String[] MODES={"system","light","dark"},MODE_TITLES={"跟随系统","浅色","深色"};
 static final String[] ACCENTS={"rose","amber","violet","graphite"},ACCENT_TITLES={"胭脂","琥珀","紫藤","石墨"};
 static int index(String[] choices,String value){for(int i=0;i<choices.length;i++)if(choices[i].equals(value))return i;return 0;}
 static boolean dark(String mode,boolean system){return "dark".equals(mode)||!"light".equals(mode)&&system;}
 static int blend(int color,double fraction,int other){int result=0xff000000;for(int shift:new int[]{16,8,0})result|=((int)Math.round(((color>>shift)&255)*(1-fraction)+((other>>shift)&255)*fraction))<<shift;return result;}
 static int rgb(double r,double g,double b){return 0xff000000|((int)Math.round(r*255)<<16)|((int)Math.round(g*255)<<8)|(int)Math.round(b*255);}
 static int accent(String name,boolean dark){int color;switch(index(ACCENTS,name)){case 1:color=rgb(.53,.32,.06);break;case 2:color=rgb(.43,.27,.65);break;case 3:color=rgb(.32,.35,.39);break;default:color=rgb(.62,.18,.34);}return dark?blend(color,.55,0xffffffff):color;}
 static int text(boolean dark){return dark?0xfff5f5f5:0xff1a1a1a;}
 static int secondary(boolean dark){return dark?0xffc2c2c2:0xff5c5c5c;}
 static int background(boolean dark){return dark?rgb(.10,.10,.11):0xffffffff;}
 static int rail(boolean dark){return dark?rgb(.14,.14,.14):rgb(.94,.94,.94);}
 static int key(boolean dark){return dark?rgb(.20,.20,.20):0xffffffff;}
 static int selection(String accent,boolean dark){return blend(accent(accent,false),dark?.40:.86,dark?0xff000000:0xffffffff);}
 static double luminance(int color){double[] linear=new double[3];int i=0;for(int shift:new int[]{16,8,0}){double c=((color>>shift)&255)/255.0;linear[i++]=c<=.04045?c/12.92:Math.pow((c+.055)/1.055,2.4);}return .2126*linear[0]+.7152*linear[1]+.0722*linear[2];}
 static double contrast(int a,int b){double x=luminance(a),y=luminance(b);return(Math.max(x,y)+.05)/(Math.min(x,y)+.05);}
}
