import Foundation
import CryptoKit

/// One encrypted current-copy snapshot, not a history or an outgoing queue.
/// Only an already-authorized OS read/write may publish it. All I/O is utility.
public struct ClipboardPreviewCache {
    public enum Source:String,Codable {case localRead,receivedWrite}
    public struct Preview {public let text:String,source:Source}
    private struct Snapshot:Codable {
        let scope:String,generation:String,text:String;let version:Int,createdAt:UInt64;let source:Source
        init(scope:String,generation:String,text:String,version:Int,createdAt:UInt64,source:Source) {self.scope=scope;self.generation=generation;self.text=text;self.version=version;self.createdAt=createdAt;self.source=source}
        private enum CodingKeys:String,CodingKey {case scope,generation,text,version,createdAt,source}
        init(from decoder:Decoder)throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            scope=try c.decode(String.self,forKey:.scope);generation=try c.decode(String.self,forKey:.generation)
            text=try c.decode(String.self,forKey:.text);version=try c.decode(Int.self,forKey:.version);createdAt=try c.decode(UInt64.self,forKey:.createdAt)
            // Existing76 snapshots never claim a proven remote write.
            source=try c.decodeIfPresent(Source.self,forKey:.source) ?? .localRead
        }
    }
    private let file:URL
    private static let aad=Data("PrivateInput/current-clipboard-preview/v1\0".utf8)
    public init(directory:URL) {file=directory.appendingPathComponent("clipboard-preview-v1.enc")}
    @discardableResult public func publish(text:String,scope:String,version:Int,generation:String,now:UInt64,key:SymmetricKey,source:Source = .localRead)throws->Bool {
        guard key.bitCount==256,version>=0,!scope.isEmpty,scope.utf8.count<=512,!generation.isEmpty,generation.utf8.count<=128,
              !text.isEmpty,!text.contains("\0"),text.utf8.count<=65536 else {throw ClipboardCacheError.invalidCache}
        // Caller holds the same cross-process lock used by pending storage.
        // A utility job for an older copy must not replace a newer live one.
        if let old=try? snapshot(key:key),old.scope==scope,old.generation==generation,
           (old.createdAt>now || now-old.createdAt<=600),
           (old.version>version || (old.version==version &&
             ((old.createdAt>now && !(old.source == .localRead && source == .receivedWrite)) ||
              (old.source == .receivedWrite && source == .localRead)))) {return false}
        let data=try JSONEncoder().encode(Snapshot(scope:scope,generation:generation,text:text,version:version,createdAt:now,source:source))
        let box=try ChaChaPoly.seal(data,using:key,authenticating:Self.aad).combined
        guard box.count<=128*1024 else {throw ClipboardCacheError.oversized}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        #if os(iOS)
        try box.write(to:file,options:[.atomic,.completeFileProtection])
        #else
        try box.write(to:file,options:.atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        return true
    }
    private func snapshot(key:SymmetricKey)throws->Snapshot? {
        guard FileManager.default.fileExists(atPath:file.path) else{return nil}
        let h=try FileHandle(forReadingFrom:file);defer{try? h.close()}
        let raw=try h.read(upToCount:128*1024+1) ?? Data()
        guard raw.count<=128*1024,key.bitCount==256 else {throw ClipboardCacheError.invalidCache}
        let plain=try ChaChaPoly.open(.init(combined:raw),using:key,authenticating:Self.aad)
        return try JSONDecoder().decode(Snapshot.self,from:plain)
    }
    public func read(scope:String,version:Int,generation:String,now:UInt64,key:SymmetricKey)throws->String? {
        try readPreview(scope:scope,version:version,generation:generation,now:now,key:key,localReadAllowed:true)?.text
    }
    public func readPreview(scope:String,version:Int,generation:String,now:UInt64,key:SymmetricKey,localReadAllowed:Bool)throws->Preview? {
        guard let s=try snapshot(key:key) else{return nil}
        guard s.scope==scope,s.version==version,s.generation==generation,s.createdAt<=now,now-s.createdAt<=600,
              !s.text.isEmpty,!s.text.contains("\0"),s.text.utf8.count<=65536,
              localReadAllowed || s.source == .receivedWrite else{return nil}
        return Preview(text:s.text,source:s.source)
    }
    public func clear()throws {if FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}}
}
