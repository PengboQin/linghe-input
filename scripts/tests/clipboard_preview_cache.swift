import Foundation
import CryptoKit
// Only error/model boundary; the exact production cache implementation is used.
public enum ClipboardCacheError:Error {case permissionRequired,invalidCache,oversized}
@main enum PreviewChecks {
 static func main()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("linghe-current-preview-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let cache=ClipboardPreviewCache(directory:root),key=SymmetricKey(size:.bits256)
  var checks=0
  func check(_ v:Bool,_ name:String){precondition(v,name);checks+=1}
  let original="  synthetic\r\n\n    indent 👩🏽‍💻  "
  try cache.publish(text:original,scope:"scope",version:2,generation:"gen",now:100,key:key)
  check(try cache.read(scope:"scope",version:2,generation:"gen",now:100,key:key)==original,"one exact authorized copy")
  // An outgoing queue can disappear without removing this independent preview.
  check(try ClipboardPreviewCache(directory:root).read(scope:"scope",version:2,generation:"gen",now:101,key:key)==original,"reopen does not depend on upload pending")
  check(try cache.read(scope:"other",version:2,generation:"gen",now:100,key:key)==nil,"scope fenced")
  check(try cache.read(scope:"scope",version:3,generation:"gen",now:100,key:key)==nil,"clipboard version fenced")
  check(try cache.read(scope:"scope",version:2,generation:"new",now:100,key:key)==nil,"departure fenced")
  check(try cache.read(scope:"scope",version:2,generation:"gen",now:99,key:key)==nil,"future-clock snapshot rejected")
  check(try cache.read(scope:"scope",version:2,generation:"gen",now:700,key:key)==original,"bounded TTL edge")
  check(try cache.read(scope:"scope",version:2,generation:"gen",now:701,key:key)==nil,"expired copy not shown")
  let file=root.appendingPathComponent("clipboard-preview-v1.enc")
  check(!(try Data(contentsOf:file)).contains(Data(original.utf8)),"no plaintext file")
  try cache.publish(text:"replacement",scope:"scope",version:3,generation:"gen",now:101,key:key)
  check(try cache.read(scope:"scope",version:2,generation:"gen",now:101,key:key)==nil,"replace never retains history")
  check(try cache.read(scope:"scope",version:3,generation:"gen",now:101,key:key)=="replacement","newest snapshot")
  check(try cache.publish(text:"late old job",scope:"scope",version:2,generation:"gen",now:102,key:key)==false,"older queued copy cannot replace newer snapshot")
  check(try cache.read(scope:"scope",version:3,generation:"gen",now:102,key:key)=="replacement","newer copy remains available after stale publisher")
  check(try cache.readPreview(scope:"scope",version:3,generation:"gen",now:102,key:key,localReadAllowed:false)==nil,"paused local clipboard read hides a local-read snapshot")
  try cache.publish(text:"received",scope:"scope",version:3,generation:"gen",now:103,key:key,source:.receivedWrite)
  let received=try cache.readPreview(scope:"scope",version:3,generation:"gen",now:103,key:key,localReadAllowed:false)
  check(received?.text=="received" && received?.source == .receivedWrite,"proven system-board write preview survives unrelated local read pause")
  check(try cache.publish(text:"local callback",scope:"scope",version:3,generation:"gen",now:104,key:key)==false,"local callback cannot downgrade proof of same remote write")
  check(try cache.readPreview(scope:"scope",version:4,generation:"gen",now:104,key:key,localReadAllowed:false)==nil,"received preview still fenced by current board version")
  check(try cache.readPreview(scope:"scope",version:3,generation:"other",now:104,key:key,localReadAllowed:false)==nil,"received preview still fenced by consent generation")
  check(try cache.readPreview(scope:"scope",version:3,generation:"gen",now:704,key:key,localReadAllowed:false)==nil,"received preview still expires")
  try cache.publish(text:"new local",scope:"scope",version:4,generation:"gen",now:104,key:key)
  check(try cache.readPreview(scope:"scope",version:4,generation:"gen",now:104,key:key,localReadAllowed:false)==nil,"a genuinely newer local copy is not remote-classified")
  //76 wire snapshots did not encode a source. Decode conservatively as local.
  let aad=Data("PrivateInput/current-clipboard-preview/v1\0".utf8)
  let raw=try Data(contentsOf:file)
  var object=try JSONSerialization.jsonObject(with:ChaChaPoly.open(.init(combined:raw),using:key,authenticating:aad)) as! [String:Any]
  object.removeValue(forKey:"source")
  let legacy=try ChaChaPoly.seal(JSONSerialization.data(withJSONObject:object),using:key,authenticating:aad).combined
  try legacy.write(to:file)
  check(try cache.readPreview(scope:"scope",version:4,generation:"gen",now:104,key:key,localReadAllowed:false)==nil,"legacy source-free snapshot never bypasses paused local reading")
  var bad=try Data(contentsOf:file);bad[bad.count-1] ^= 1;try bad.write(to:file)
  do{_=try cache.read(scope:"scope",version:3,generation:"gen",now:101,key:key);preconditionFailure("tamper accepted")}catch{checks+=1}
  try cache.clear();check(try cache.read(scope:"scope",version:3,generation:"gen",now:101,key:key)==nil,"reset erases snapshot")
  print("CLIPBOARD_CURRENT_PREVIEW_CHECKS=\(checks)")
 }
}
