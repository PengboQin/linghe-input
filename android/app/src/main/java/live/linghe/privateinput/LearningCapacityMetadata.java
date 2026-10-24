package live.linghe.privateinput;

import java.io.IOException;
import org.json.JSONObject;

/** Explicit profile identities. Never derives a larger limit from input data. */
final class LearningCapacityMetadata {
 private LearningCapacityMetadata() {}
 static LearningCapacityProfiles.Profile checked(LearningCapacityProfiles.Profile value) {
  if(value==null)throw new IllegalArgumentException("Missing learning capacity profile");
  return LearningCapacityProfiles.require(value.id,value.version);
 }
 static boolean legacy(LearningCapacityProfiles.Profile value){return checked(value)==LearningCapacityProfiles.LEGACY_5000;}
 static JSONObject encode(LearningCapacityProfiles.Profile value)throws Exception {
  value=checked(value);
  return new JSONObject().put("profile_id",value.id).put("profile_version",value.version);
 }
 static LearningCapacityProfiles.Profile decode(JSONObject value)throws Exception {
  if(value.length()!=2||!value.has("profile_id")||!value.has("profile_version"))throw new IOException("Invalid learning capacity metadata");
  return LearningCapacityProfiles.require(PersonalLexicon.string(value,"profile_id"),LosslessJson.unsigned(value.get("profile_version")).intValueExact());
 }
 static void allowMerge(LearningCapacityProfiles.Profile target,LearningCapacityProfiles.Profile incoming)throws IOException {
  target=checked(target);incoming=checked(incoming);
  if(target==LearningCapacityProfiles.LEGACY_5000&&incoming!=target)throw new IOException("Learning capacity upgrade required");
 }
 static LearningCapacityProfiles.Profile archive(JSONObject value,int legacyVersion,int expandedVersion)throws Exception {
  int version=LosslessJson.unsigned(value.get("version")).intValueExact();
  if(version==legacyVersion&&!value.has("capacity_profile"))return LearningCapacityProfiles.LEGACY_5000;
  if(version==expandedVersion&&value.has("capacity_profile")){
   LearningCapacityProfiles.Profile profile=decode(value.getJSONObject("capacity_profile"));
   if(profile==LearningCapacityProfiles.EXPANDED_10000)return profile;
  }
  throw new IOException("Incompatible learning capacity schema");
 }
}
