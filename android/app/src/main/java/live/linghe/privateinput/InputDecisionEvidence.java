package live.linghe.privateinput;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

/** Immutable, bounded process evidence. JSON and persistence belong to archive storage. */
final class InputDecisionEvidence {
 static final String KEY="org.linghe.decision.v1",LINK="org.linghe.decision-link.v1";
 static final String CLOCK=UUID.randomUUID().toString();
 final String composition,state,decision,stage,snapshot,raw,method,reason,output;
 final String markedText,markedStatus;final String pressState,releaseState;final long pressMicros,releaseMicros;final String modelVersion;final Boolean localOverlay;final long revision,micros;final List<Candidate> candidates;final Candidate selected;final boolean truncated;
 static final class Candidate {
  final String id,text,reading,source;final int rank;final boolean textTruncated;
  Candidate(String id,String text,String reading,int rank,String source){this.id=id;this.textTruncated=text.getBytes(StandardCharsets.UTF_8).length>256;this.text=bounded(text,256);this.reading=bounded(reading,256);this.rank=rank;this.source=source;}
 }
 InputDecisionEvidence(String composition,long revision,String state,String decision,String stage,String snapshot,String raw,List<Candidate> candidates,Candidate selected,String method,String reason,String output,long micros,boolean truncated){
  this(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,null,null);
 }
 InputDecisionEvidence(String composition,long revision,String state,String decision,String stage,String snapshot,String raw,List<Candidate> candidates,Candidate selected,String method,String reason,String output,long micros,boolean truncated,String modelVersion,Boolean localOverlay){
  this(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,modelVersion,localOverlay,null,null,-1,-1);
 }
 InputDecisionEvidence(String composition,long revision,String state,String decision,String stage,String snapshot,String raw,List<Candidate> candidates,Candidate selected,String method,String reason,String output,long micros,boolean truncated,String modelVersion,Boolean localOverlay,String pressState,String releaseState,long pressMicros,long releaseMicros){
  this(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,modelVersion,localOverlay,pressState,releaseState,pressMicros,releaseMicros,null,null);
 }
 InputDecisionEvidence(String composition,long revision,String state,String decision,String stage,String snapshot,String raw,List<Candidate> candidates,Candidate selected,String method,String reason,String output,long micros,boolean truncated,String modelVersion,Boolean localOverlay,String pressState,String releaseState,long pressMicros,long releaseMicros,String markedText,String markedStatus){
  this.markedText=markedText==null?null:bounded(markedText,4096);this.markedStatus=markedStatus;this.pressState=pressState;this.releaseState=releaseState;this.pressMicros=pressMicros;this.releaseMicros=releaseMicros;this.modelVersion=modelVersion;this.localOverlay=localOverlay;this.composition=composition;this.revision=revision;this.state=state;this.decision=decision;this.stage=stage;this.snapshot=snapshot;this.raw=bounded(raw,2048);this.candidates=Collections.unmodifiableList(new ArrayList<>(candidates.subList(0,Math.min(5,candidates.size()))));this.selected=selected;this.method=method;this.reason=reason;this.output=output;this.micros=micros;this.truncated=truncated;
 }
 static String bounded(String value,int bytes){if(value==null)return "";if(value.length()<=bytes/4)return value;StringBuilder out=new StringBuilder();int size=0;for(int i=0;i<value.length();){int cp=value.codePointAt(i),n=cp<=127?1:cp<=2047?2:cp<=65535?3:4;if(size+n>bytes)break;out.appendCodePoint(cp);size+=n;i+=Character.charCount(cp);}return out.toString();}
 static String id(String snapshot,String rawID){try{MessageDigest hash=MessageDigest.getInstance("SHA-256");byte[] bytes=hash.digest(rawID.getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder(snapshot+"_");for(int i=0;i<8;i++)out.append(String.format(Locale.ROOT,"%02x",bytes[i]&255));return out.toString();}catch(Exception impossible){throw new AssertionError(impossible);}}
 static String source(String id){return id.startsWith("custom:")?"personal":id.startsWith("repair:")?"correction":id.startsWith("continuation:")?"semantic":id.startsWith("english:")?"public":"unknown";}
 static Candidate candidate(String snapshot,String[] row,int rank){return new Candidate(id(snapshot,row[0]),row[1],row.length>2?row[2]:"",rank,source(row[0]));}
 InputDecisionEvidence event(String stage,Candidate selected,String method,String reason,String output,long micros){return new InputDecisionEvidence(composition,revision,state,decision,stage,snapshot,raw,stage.equals("candidates")?candidates:Collections.emptyList(),selected,method,reason,output,micros,truncated,modelVersion,localOverlay,pressState,releaseState,pressMicros,releaseMicros,markedText,markedStatus);}
 InputDecisionEvidence model(String modelVersion,Boolean localOverlay){return new InputDecisionEvidence(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,modelVersion,localOverlay,pressState,releaseState,pressMicros,releaseMicros,markedText,markedStatus);}
 InputDecisionEvidence touch(InputDecisionEvidence press,InputDecisionEvidence release){return new InputDecisionEvidence(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,modelVersion,localOverlay,press==null?null:press.state,release==null?null:release.state,press==null?-1:press.micros,release==null?-1:release.micros,markedText,markedStatus);}
 InputDecisionEvidence marked(String text,String status){return new InputDecisionEvidence(composition,revision,state,decision,stage,snapshot,raw,candidates,selected,method,reason,output,micros,truncated,modelVersion,localOverlay,pressState,releaseState,pressMicros,releaseMicros,text,status);}
 static final class Scope {
  private long current=1;
  synchronized long current(){return current;}
  synchronized void advance(){current++;}
  synchronized boolean accepts(long token){return token!=0&&token==current;}
  static final class Frozen {final String session,epoch;Frozen(String session,String epoch){this.session=session;this.epoch=epoch;}}
  synchronized Frozen freeze(long expected,boolean safe,boolean enabled,String session,String epoch){return accepts(expected)&&safe&&enabled?new Frozen(session,epoch):null;}
 }
 static final class CommitPermission {
  final boolean output,diagnostic,link;
  CommitPermission(boolean safe,boolean inputAllowed,boolean diagnosticAllowed,boolean currentScope,boolean captured){output=safe&&inputAllowed;diagnostic=safe&&diagnosticAllowed&&currentScope&&captured;link=output&&diagnostic;}
 }
 static final class Owner {
  private String composition=UUID.randomUUID().toString();private long revision;private boolean ended=true;
  synchronized void reset(){composition=UUID.randomUUID().toString();revision=0;ended=true;}
  synchronized InputDecisionEvidence snapshot(String raw,String[][] rows,long micros){if(ended&&!raw.isEmpty()){composition=UUID.randomUUID().toString();revision=0;}String state=UUID.randomUUID().toString();ArrayList<Candidate> values=new ArrayList<>();for(int i=1;i<Math.min(rows.length,6);i++)values.add(candidate(state,rows[i],i-1));ended=raw.isEmpty();boolean textCut=values.stream().anyMatch(value->value.textTruncated);return new InputDecisionEvidence(composition,++revision,state,UUID.randomUUID().toString(),"candidates",state,raw,values,null,null,textCut?"candidate_text_too_large":null,null,micros,rows.length-1>5||textCut);}
 }
}
