package live.linghe.privateinput;
import java.util.Locale;
/** Immutable observed sender slot. A new push CASes this exact event, never arrival time. */
final class RecentLearningSlot {
 final String publishedEvent;
 RecentLearningSlot(String published,String envelopeEvent,String expectedSender,String envelopeSender)throws Exception{
  RecentLearning.require(published!=null&&expectedSender!=null,"Missing recency sender slot");RecentLearningWire.uuid(expectedSender);
  if(published.isEmpty()){RecentLearning.require(envelopeEvent==null&&envelopeSender==null,"Empty slot contains envelope");publishedEvent="";}
  else{RecentLearningWire.uuid(published);RecentLearning.require(envelopeEvent!=null&&envelopeSender!=null,"Slot snapshot missing");RecentLearningWire.uuid(envelopeEvent);RecentLearningWire.uuid(envelopeSender);RecentLearning.require(published.equalsIgnoreCase(envelopeEvent)&&expectedSender.equalsIgnoreCase(envelopeSender),"Slot envelope identity mismatch");publishedEvent=published.toUpperCase(Locale.ROOT);}
 }
 boolean shouldPush(String digest,String previousDigest,long previousTime,long serverNow){return publishedEvent.isEmpty()||!digest.equals(previousDigest)||previousTime>serverNow||serverNow-previousTime>=86400;}
 boolean accepted(String returnedEvent,String attemptedEvent)throws Exception{RecentLearningWire.uuid(returnedEvent);RecentLearningWire.uuid(attemptedEvent);return returnedEvent.equalsIgnoreCase(attemptedEvent);}
}
