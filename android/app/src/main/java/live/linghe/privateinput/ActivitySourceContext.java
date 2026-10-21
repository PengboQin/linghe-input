package live.linghe.privateinput;

import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** Inert, bounded provenance. No window title, process path or guessed copy source. */
final class ActivitySourceContext {
  static final String KEY="org.linghe.context.v1";
  static Map<String,String> fields(String platform,String appID,String appName,String version,String build,
      String fieldType,String returnKey,String layout,String component){
    String id=bounded(appID,256);
    if(id!=null&&(id.contains("/")||id.contains("\\")))id=null;
    String name=id==null?null:bounded(appName,256);
    LinkedHashMap<String,String> value=new LinkedHashMap<>();
    value.put("platform",or(bounded(platform,24),"unknown"));
    value.put("app_identity_status",id==null?"unavailable":name==null?"identifier_only":"available");
    value.put("capture_component",or(bounded(component,48),"unknown"));
    if(id!=null)value.put("source_app_id",id);
    if(name!=null)value.put("source_app_name",name);
    value.put("input_method_version",or(bounded(version,64),"unavailable"));
    value.put("input_method_build",or(bounded(build,64),"unavailable"));
    value.put("field_type",or(bounded(fieldType,64),"unavailable"));
    value.put("return_key",or(bounded(returnKey,64),"unavailable"));
    value.put("layout",or(bounded(layout,64),"unavailable"));
    return Collections.unmodifiableMap(value);
  }
  private static String or(String value,String fallback){return value==null?fallback:value;}
  private static String bounded(String value,int bytes){
    if(value==null)return null;String text=value.trim();
    if(text.isEmpty()||text.getBytes(StandardCharsets.UTF_8).length>bytes)return null;
    for(int i=0;i<text.length();i++)if(Character.isISOControl(text.charAt(i)))return null;
    return text;
  }
}
