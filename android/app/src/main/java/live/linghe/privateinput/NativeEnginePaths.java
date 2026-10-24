package live.linghe.privateinput;
import java.io.File;
/** Preserve the EXACT pair used by successful pi_initialize. Canonical and
 * literal aliases may name one inode but are deliberately distinct to core. */
final class NativeEnginePaths {
 final String shared,user;
 private NativeEnginePaths(String shared,String user){this.shared=shared;this.user=user;}
 static NativeEnginePaths prepared(File shared,File user){return new NativeEnginePaths(shared.getAbsolutePath(),user.getAbsolutePath());}
 boolean samePair(String shared,String user){return this.shared.equals(shared)&&this.user.equals(user);}
}
