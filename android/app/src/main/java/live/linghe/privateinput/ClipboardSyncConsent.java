package live.linghe.privateinput;

import android.content.SharedPreferences;

/** One visible switch; retain both protocol grants and their in-flight fences. */
final class ClipboardSyncConsent {
  static final String AUTOMATIC="automatic-clipboard",AUTOMATIC_GENERATION="automatic-clipboard-generation";
  private ClipboardSyncConsent(){}
  static boolean enabled(SharedPreferences prefs){
    return prefs.getBoolean("clipboard",false)&&prefs.getBoolean(AUTOMATIC,false);
  }
  static boolean set(SharedPreferences prefs,boolean enabled){
    synchronized(SyncClient.CONSENT_LOCK){
      // A legacy manual-sharing grant alone never enables automatic observation.
      // Commit both grants atomically; callbacks cannot observe a half-enabled pair.
      boolean saved=prefs.edit().putBoolean("clipboard",enabled).putBoolean(AUTOMATIC,enabled)
          .putLong("generation",prefs.getLong("generation",0)+1)
          .putLong(AUTOMATIC_GENERATION,prefs.getLong(AUTOMATIC_GENERATION,0)+1).commit();
      if(!saved){
        // Android may update the in-memory map even if disk persistence fails.
        // Fence observation immediately; a later explicit retry must commit again.
        prefs.edit().putBoolean("clipboard",false).putBoolean(AUTOMATIC,false)
            .putLong("generation",prefs.getLong("generation",0)+1)
            .putLong(AUTOMATIC_GENERATION,prefs.getLong(AUTOMATIC_GENERATION,0)+1).commit();
      }
      return saved;
    }
  }
}
