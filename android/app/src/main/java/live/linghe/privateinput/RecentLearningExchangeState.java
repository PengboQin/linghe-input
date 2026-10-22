package live.linghe.privateinput;
import java.io.IOException;
import java.util.*;
/** Small event-id cache and monotonic cadence, scoped to one authenticated
 * membership. It contains no input text and never decides merge semantics. */
final class RecentLearningExchangeState {
 static final long SUCCESS_MS=10*60*1000L,FAILURE_MS=30*1000L;
 final String binding;boolean conditional;
 final Map<String,String> known=new TreeMap<>();
 boolean attemptSucceeded;long attemptMs=-1,successMs=-1;String attemptBoot="",successBoot="";
 RecentLearningExchangeState(String binding){this.binding=binding;}
 private static String id(String value)throws IOException{
  try{UUID parsed=UUID.fromString(value);if(!parsed.toString().equalsIgnoreCase(value))throw new IllegalArgumentException();return parsed.toString().toUpperCase(Locale.ROOT);}
  catch(Exception bad){throw new IOException("Invalid recent known event identity");}
 }
 void restoreKnown(Map<String,String> values)throws IOException{if(values.size()>64)throw new IOException("Too many recent snapshot slots");Map<String,String> validated=new TreeMap<>();for(Map.Entry<String,String> item:values.entrySet()){String sender=id(item.getKey());if(validated.put(sender,id(item.getValue()))!=null)throw new IOException("Duplicate recent snapshot sender");}known.clear();known.putAll(validated);}
 String knownEvent(String sender)throws IOException{return conditional?known.get(id(sender)):null;}
 boolean due(long uptime,String boot){return due(uptime,boot,false);}
 boolean due(long uptime,String boot,boolean explicit){
  if(uptime<0||boot==null||boot.isEmpty())return false;
  if(!attemptSucceeded&&attemptBoot.equals(boot)&&attemptMs>=0&&uptime>=attemptMs&&uptime-attemptMs<FAILURE_MS)return false;
  return explicit||!successBoot.equals(boot)||successMs<0||uptime<successMs||uptime-successMs>=SUCCESS_MS;
 }
 void attempted(long uptime,String boot){attemptMs=uptime;attemptBoot=boot;attemptSucceeded=false;}
 void succeeded(long uptime,String boot){successMs=uptime;successBoot=boot;attemptMs=uptime;attemptBoot=boot;attemptSucceeded=true;}
 interface DurableMerge{void run()throws Exception;}
 void merged(String sender,String event,DurableMerge durable)throws Exception{
  String key=id(sender),value=id(event);if(!known.containsKey(key)&&known.size()>=64)throw new IOException("Too many recent snapshot slots");
  durable.run(); // Failure must leave the skip hint unchanged.
  known.put(key,value);
 }
}
