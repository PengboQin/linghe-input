import Foundation
import CryptoKit
import CSQLite
import Darwin

public enum ClipboardOnceError:Error {case invalid, unavailable}

/// Device-local automatic-action receipts. No text, sender, event or timestamp
/// is stored. Never evict: a full/unavailable store suppresses automatic actions.
/// Call on a utility worker; SQLite arbitrates containing app/extension owners.
public struct ClipboardOnceReceipts {
    public enum Kind:Int32 {case delivery=1,candidate=2}
    private let directory:URL
    public init(directory:URL) {self.directory=directory.appendingPathComponent("ClipboardOnce",isDirectory:true)}
    public func claim(_ kind:Kind,texts:[String],validating:()->Bool={true})throws->[Bool] {
        guard texts.count<=32,texts.allSatisfy({!$0.isEmpty && !$0.contains("\0") && $0.utf8.count<=65536}) else {throw ClipboardOnceError.invalid}
        guard validating() else {return Array(repeating:false,count:texts.count)}
        if texts.isEmpty {return []}
        let fm=FileManager.default
        guard (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else {throw ClipboardOnceError.unavailable}
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Foundation may normalize /private/var back to /var. SQLite NOFOLLOW
        // needs the actual canonical parent (including system temp/App Groups).
        guard let canonical=realpath(directory.path,nil) else {throw ClipboardOnceError.unavailable}
        let canonicalPath=String(cString:canonical);free(canonical)
        let file=URL(fileURLWithPath:canonicalPath).appendingPathComponent("receipts-v1.sqlite")
        var handle:OpaquePointer?
        guard sqlite3_open_v2(file.path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK,let db=handle else {
            if let handle {sqlite3_close(handle)};throw ClipboardOnceError.unavailable
        }
        defer {sqlite3_close(db)}
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:file.path)
        #endif
        sqlite3_busy_timeout(db,0)
        func execute(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw ClipboardOnceError.unavailable}}
        func prepare(_ sql:String)throws->OpaquePointer {
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else {throw ClipboardOnceError.unavailable};return statement
        }
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        func bind(_ data:Data,_ statement:OpaquePointer,_ index:Int32)throws {
            let result=data.withUnsafeBytes {sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(data.count),transient)}
            guard result==SQLITE_OK else {throw ClipboardOnceError.unavailable}
        }
        try execute("PRAGMA page_size=4096; PRAGMA max_page_count=4096; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;")
        var committed=false;defer {if !committed {try? execute("ROLLBACK")}}
        try execute("CREATE TABLE IF NOT EXISTS metadata(id INTEGER PRIMARY KEY,salt BLOB NOT NULL); CREATE TABLE IF NOT EXISTS seen(kind INTEGER NOT NULL,fingerprint BLOB NOT NULL,PRIMARY KEY(kind,fingerprint)) WITHOUT ROWID;")
        let salt:Data=try {
            let query=try prepare("SELECT salt FROM metadata WHERE id=1");defer{sqlite3_finalize(query)}
            let status=sqlite3_step(query)
            if status==SQLITE_ROW,sqlite3_column_bytes(query,0)==32,let bytes=sqlite3_column_blob(query,0) {return Data(bytes:bytes,count:32)}
            guard status==SQLITE_DONE else {throw ClipboardOnceError.unavailable}
            let salt=SymmetricKey(size:.bits256).withUnsafeBytes {Data($0)}
            let insert=try prepare("INSERT INTO metadata(id,salt) VALUES(1,?)");defer{sqlite3_finalize(insert)}
            try bind(salt,insert,1);guard sqlite3_step(insert)==SQLITE_DONE else {throw ClipboardOnceError.unavailable};return salt
        }()
        let insert=try prepare("INSERT OR IGNORE INTO seen(kind,fingerprint) VALUES(?,?)");defer{sqlite3_finalize(insert)}
        var newlyClaimed=Set<Data>(),result:[Bool]=[]
        for text in texts {
            let digest=Data(HMAC<SHA256>.authenticationCode(for:Data(text.utf8),using:SymmetricKey(data:salt)))
            sqlite3_reset(insert);sqlite3_clear_bindings(insert)
            guard sqlite3_bind_int(insert,1,kind.rawValue)==SQLITE_OK else {throw ClipboardOnceError.unavailable}
            try bind(digest,insert,2)
            guard sqlite3_step(insert)==SQLITE_DONE else {throw ClipboardOnceError.unavailable}
            if sqlite3_changes(db)==1 {newlyClaimed.insert(digest)}
            // Same-batch copies share one receipt; the chosen newest event can
            // still deliver it. Subsequent transactions all see it as consumed.
            result.append(newlyClaimed.contains(digest))
        }
        guard validating() else {return Array(repeating:false,count:texts.count)}
        try execute("COMMIT");committed=true;return result
    }
}
