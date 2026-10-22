package live.linghe.privateinput;
import java.util.*;import org.json.*;
/** In-memory logical JSON body counts only. Never stores URL/group/identity,
 * request/response bodies or text. HTTP/TLS overhead is measured separately by UID. */
final class SyncTransferMetrics {
 private static final Map<String,long[]> rows=new TreeMap<>();
 static synchronized void record(String lane,long sent,long received,long millis,boolean success){long[] value=rows.computeIfAbsent(lane,key->new long[5]);value[0]++;value[1]+=Math.max(0,sent);value[2]+=Math.max(0,received);value[3]+=Math.max(0,millis);if(!success)value[4]++;}
 static String lane(String path,JSONObject request){if(path.equals("/v1/learning/rpc"))return "cloud-op"+request.optInt("operation",0);if(path.endsWith("/recency"))return "recency-op"+request.optInt("operation",0);if(path.endsWith("/events"))return request.optInt("domain",0)==1?"learning-v1":"clipboard-v1";if(path.endsWith("/rpc"))return "relay-rpc";return "relay-metadata";}
 static synchronized JSONObject snapshot()throws Exception{JSONObject result=new JSONObject();for(Map.Entry<String,long[]> row:rows.entrySet()){long[] value=row.getValue();result.put(row.getKey(),new JSONObject().put("requests",value[0]).put("attemptedRequestBodyBytes",value[1]).put("receivedBodyBytes",value[2]).put("durationMs",value[3]).put("failures",value[4]));}return new JSONObject().put("processLifetimeOnly",true).put("bodyCountsExcludeHTTPAndTLS",true).put("lanes",result);}
}
