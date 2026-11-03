package live.linghe.privateinput;
import java.util.function.BooleanSupplier;
/** Main-executor delivery: candidate cancellation must not discard accepted input. */
final class InputActionDelivery {
 static void execute(ImeTaskExecutors.Prioritized worker,BooleanSupplier sameDocument,Runnable action,Runnable finished){worker.executeHigh(()->{try{if(sameDocument.getAsBoolean())action.run();}finally{finished.run();}});}
 static void deliver(BooleanSupplier sameDocument,Runnable commit,BooleanSupplier currentPublication,Runnable publish,Runnable after){
  if(!sameDocument.getAsBoolean())return;
  commit.run();
  if(sameDocument.getAsBoolean()&&currentPublication.getAsBoolean())publish.run();
  if(sameDocument.getAsBoolean())after.run();
 }
 private InputActionDelivery(){}
}
