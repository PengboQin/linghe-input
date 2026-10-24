package live.linghe.privateinput;
import java.io.File;import java.nio.file.*;import java.util.*;
public final class NativeEnginePathsTest {
 public static void main(String[]args)throws Exception{
  Path root=Files.createTempDirectory("linghe-native-pair-");try{
   Path actual=Files.createDirectory(root.resolve("actual")),alias=Files.createSymbolicLink(root.resolve("alias"),actual);Files.createDirectory(actual.resolve("rime-v2"));Files.createDirectory(actual.resolve("Rime"));
   File preparedShared=alias.resolve("rime-v2").toFile().getCanonicalFile(),preparedUser=alias.resolve("Rime").toFile();NativeEnginePaths pair=NativeEnginePaths.prepared(preparedShared,preparedUser);
   if(!pair.samePair(preparedShared.getAbsolutePath(),preparedUser.getAbsolutePath()))throw new AssertionError("successful pair changed");
   if(pair.samePair(alias.resolve("rime-v2").toFile().getAbsolutePath(),preparedUser.getAbsolutePath()))throw new AssertionError("literal reconstruction unexpectedly equal");
   if(!preparedShared.equals(alias.resolve("rime-v2").toFile().getCanonicalFile()))throw new AssertionError("fixture does not prove alias identity");
   if(!pair.shared.equals(preparedShared.getAbsolutePath())||!pair.user.equals(preparedUser.getAbsolutePath()))throw new AssertionError("pair must not re-canonicalize one side");
   System.out.println("PASS exact prepared pair retained across canonical/literal alias; no native/device/UI execution");
  }finally{try(java.util.stream.Stream<Path> paths=Files.walk(root)){paths.sorted(Comparator.reverseOrder()).forEach(p->{try{Files.delete(p);}catch(Exception e){throw new RuntimeException(e);}});}}
 }
}
