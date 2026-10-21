package live.linghe.privateinput;
public final class NativeCore {
 static {System.loadLibrary("linghe");}
 public static native long create(String resources,String user);
 public static native void destroy(long session);
 public static native boolean closeForCheckpoint(long session);
 public static native boolean languageInitialize(String folder);
 public static native double languageScore(String before,String text);
 public static native int exportLearning(String file);
 public static native int importLearning(String file);
 public static native int resetFrequency(String reading,String text,long count);
 public static native boolean pin(String reading,String text,boolean pinned);
 public static native void key(long session,int code);
 public static native boolean moveCursor(long session,int direction);
 public static native boolean atEnd(long session);
 public static native boolean hasPending(long session);
 public static native String[] draft(long session);
 public static native void clear(long session);
 public static native void mode(long session,boolean nine,boolean privateMode);
 public static native void choose(long session,long index);
 public static native boolean acceptFirst(long session);
 public static native String[][] snapshot(long session);
 public static native String[][] query(long session,String input,boolean nine,int limit);
 public static native String[][] initials(long session,String input,int limit);
 public static native long editableStart(long session);
 public static native String[] commitAlternative(long session,String expected,String spelling,String text,String remainder);
 public static native String[][] more(long session,int offset);
 public static native String[] syllables(long session);
 public static native void filter(long session,int index);
 public static native void delete(long session);
}
