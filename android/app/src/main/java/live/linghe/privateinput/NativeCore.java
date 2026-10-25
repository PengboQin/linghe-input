package live.linghe.privateinput;
public final class NativeCore {
 static {System.loadLibrary("linghe");}
 public static native long create(String resources,String user);
 public static native void destroy(long session);
 public static native boolean closeForCheckpoint(long session);
 public static native boolean languageInitialize(String folder);
 /** Shared automatic-candidate admission only; never rewrite literal or stored text. */
 public static native boolean candidateTextAllowed(String text);
 // 2 new phrase, 1 known, 0 not eligible, -1 vocabulary unavailable. File I/O: worker only.
 public static native int autoPhraseStatus(String text);
 // Undo an automatically memorized new phrase; 1 forgotten, 0 absent/known, -1 invalid.
 public static native int forgetPhrase(String reading,String text);
 // Teach an eligible new phrase committed outside Rime (nine-key preferred path); 1 learned.
 public static native int learnPhrase(String reading,String text);
 /** Pure automatic reading admission; no Rime session, lock or file access. */
 public static native boolean candidateReadingAllowed(String text,String reading);
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
 /** Ephemeral, validated continuity of a displayed full nine-key reading. */
 public static native boolean rememberNinePath(long session,String raw,String selectedPrefix,String reading);
 public static native boolean rememberMappedNinePath(long session,String raw,String selectedPrefix,String reading,String canonicalCode);
 public static native String preferredNineReading(long session);
 public static native int[] ninePathPriorities(long session,String[] readings);
 public static native boolean rememberVisibleNinePath(long session,String raw,String selectedPrefix,String text,String reading,String canonicalCode);
 public static native String preferredNineText(long session);
 public static native String commitPreferredNine(long session,String raw,String selectedPrefix,String text,String reading);
 public static native boolean selectPreferredNinePrefix(long session,String raw,String selectedPrefix,String text,String reading);
 public static native String readableDraft(long session,String reading);
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
