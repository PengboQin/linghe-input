package live.linghe.privateinput;
import java.util.function.BooleanSupplier;import java.util.concurrent.Executor;
/** Main-executor delivery: candidate cancellation must not discard accepted input. */
final class InputActionDelivery {
 static void execute(Executor worker,BooleanSupplier sameDocument,Runnable action,Runnable finished){worker.execute(()->{try{if(sameDocument.getAsBoolean())action.run();}finally{finished.run();}});}
 static void deliver(BooleanSupplier sameDocument,Runnable commit,BooleanSupplier currentPublication,Runnable publish,Runnable after){
  if(!sameDocument.getAsBoolean())return;
  commit.run();
  if(sameDocument.getAsBoolean()&&currentPublication.getAsBoolean())publish.run();
  if(sameDocument.getAsBoolean())after.run();
 }
 private InputActionDelivery(){}
}
