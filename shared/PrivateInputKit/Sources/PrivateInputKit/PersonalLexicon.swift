import Foundation
import Darwin

/// Explicit user-authored entries, separate from learned frequency.
/// Only the containing settings app writes; keyboards consume atomic snapshots.
public struct PersonalLexicon: Codable, Equatable {
    public enum Kind: String, Codable { case word, phrase }
    public struct Entry: Codable, Equatable, Identifiable {
        public var id: UUID
        public var kind: Kind
        public var text: String
        public var trigger: String
        public init(id: UUID = UUID(), kind: Kind, text: String, trigger: String) {
            self.id=id;self.kind=kind;self.text=text;self.trigger=trigger
        }
    }
    public var version = 1
    public private(set) var entries: [Entry] = []
    public internal(set) var synchronization: PersonalLexiconSync?
    public init() {}
    public static let maximumBytes = 512 * 1024
    public static func normalized(_ trigger: String) -> String {
        trigger.lowercased().replacingOccurrences(of:"ü",with:"v")
            .replacingOccurrences(of:"'",with:" ").split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
    }
    public func validate(syllables: Set<String>? = nil) throws {
        guard version==1,entries.count<=1000 else { throw InputDataError.incompatibleSchema }
        var ids=Set<UUID>(),keys=Set<String>()
        for e in entries {
            guard ids.insert(e.id).inserted,!e.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  e.text.utf8.count<=2048,!e.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }),
                  e.trigger==Self.normalized(e.trigger),!e.trigger.isEmpty,e.trigger.utf8.count<=192,
                  keys.insert(e.kind.rawValue+"\u{1f}"+e.trigger+"\u{1f}"+e.text).inserted else { throw InputDataError.invalidRecord }
            let parts=e.trigger.split(separator:" ").map(String.init)
            guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) }) else { throw InputDataError.invalidRecord }
            switch e.kind {
            case .word:
                guard parts.count<=32,parts.allSatisfy({$0.count<=8}),parts.joined().count<=96,!e.text.contains("\n"),!e.text.contains("\t"),e.text.count<=64 else { throw InputDataError.invalidRecord }
                if let syllables { guard parts.allSatisfy(syllables.contains) else { throw InputDataError.invalidRecord } }
            case .phrase:
                guard parts.count==1,(2...16).contains(e.trigger.count) else { throw InputDataError.invalidRecord }
            }
        }
        if let synchronization {
            guard try synchronization.materialized().entries == entries else { throw InputDataError.invalidRecord }
        }
    }
    public mutating func upsert(_ entry: Entry, syllables: Set<String>? = nil) throws {
        var next=self,e=entry;next.synchronization=nil;e.trigger=Self.normalized(e.trigger)
        if e.kind == .word {e.trigger=e.trigger.split(separator:" ").map{PinyinInputMatch.canonicalSyllable(String($0))}.joined(separator:" ")}
        if let i=next.entries.firstIndex(where:{$0.id==e.id}) { next.entries[i]=e } else { next.entries.append(e) }
        try next.validate(syllables:syllables);self=next
    }
    public mutating func remove(id:UUID) { synchronization=nil;entries.removeAll{$0.id==id} }
    /// Merge is all-or-nothing; local edits win UUID conflicts and identical
    /// trigger/text duplicates are ignored. Import never silently deletes data.
    public mutating func merge(_ incoming:Self,syllables:Set<String>? = nil) throws {
        try incoming.validate(syllables:syllables)
        var next=self;next.synchronization=nil
        for entry in incoming.entries where !next.entries.contains(where:{$0.id==entry.id || ($0.kind==entry.kind && $0.trigger==entry.trigger && $0.text==entry.text)}) { next.entries.append(entry) }
        try next.validate(syllables:syllables);self=next
    }
    public func matches(input:String,nineKey:Bool) -> [Entry] {
        let source=Self.normalized(input).replacingOccurrences(of:" ",with:"")
        guard !source.isEmpty,source.count<=192 else { return [] }
        // Explicit letters in a nine-key filter constrain the matching syllable.
        let locked=input.split(separator:"'").prefix { !$0.isEmpty && $0.allSatisfy({$0.isASCII && $0.isLetter}) }.map(String.init)
        return entries.filter { entry in
            if nineKey {
                guard NineKeySpelling.rawCode(source)==NineKeySpelling.encode(entry.trigger) else { return false }
                if !locked.isEmpty {
                    guard entry.kind == .word,Array(entry.trigger.split(separator:" ").prefix(locked.count).map(String.init))==locked else { return false }
                }
                return true
            }
            return entry.kind == .word ? PinyinInputMatch.isFullSpelling(source,reading:entry.trigger):source==entry.trigger.replacingOccurrences(of:" ",with:"")
        }
    }
}

public struct PersonalLexiconStore {
    public let directory: URL
    public var url:URL { directory.appendingPathComponent("personal-lexicon-v1.json") }
    private let epoch:PersonalDataEpoch
    public init(directory:URL) { self.directory=directory;epoch=PersonalDataEpoch(directory:directory) }
    public func load() throws -> PersonalLexicon {
        guard FileManager.default.fileExists(atPath:url.path) else { return PersonalLexicon() }
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size<=PersonalLexicon.maximumBytes else { throw InputDataError.oversized }
        let data=try Data(contentsOf:url);return try Self.decode(data)
    }
    public static func decode(_ data:Data) throws -> PersonalLexicon {
        guard data.count<=PersonalLexicon.maximumBytes else { throw InputDataError.oversized }
        let value=try JSONDecoder().decode(PersonalLexicon.self,from:data);try value.validate();return value
    }
    public func save(_ value:PersonalLexicon) throws {
        _ = try applying(observed:load(),edited:value)
    }
    private func write(_ value:PersonalLexicon) throws {
        try epoch.requireCurrent()
        try value.validate()
        let data=try JSONEncoder().encode(value)
        guard data.count<=PersonalLexicon.maximumBytes else { throw InputDataError.oversized }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        #if os(iOS)
        try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to:url,options:.atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func locked<T>(_ body:() throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor=Darwin.open(directory.appendingPathComponent("personal-lexicon.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor>=0 else { throw SnapshotStoreError.busy }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor,LOCK_EX)==0 else { throw SnapshotStoreError.busy }
        defer { flock(descriptor,LOCK_UN) }
        guard (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw InputDataError.invalidRecord }
        return try body()
    }
    private func replica() throws -> UUID {
        let file=directory.appendingPathComponent("personal-replica-id.txt")
        if FileManager.default.fileExists(atPath:file.path) {
            guard let id=UUID(uuidString:try String(contentsOf:file,encoding:.utf8)) else { throw InputDataError.invalidRecord }
            return id
        }
        let id=UUID();try Data(id.uuidString.utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return id
    }
    private func state(_ value:PersonalLexicon,replica:UUID) throws -> PersonalLexiconSync {
        if let synchronization=value.synchronization { return synchronization }
        var result=PersonalLexiconSync();try result.seed(value,replica:replica);return result
    }
    /// Apply only edits made against the visible revision. Entries added by a
    /// network response while a sheet was open remain in the current snapshot.
    @discardableResult public func applying(observed:PersonalLexicon,edited:PersonalLexicon) throws -> PersonalLexicon {
        try observed.validate();try edited.validate()
        return try locked {
            let current=try load(),id=try replica();var sync=try state(current,replica:id)
            for old in observed.entries where !edited.entries.contains(where:{$0.id==old.id}) { try sync.change(old,deleted:true,replica:id) }
            for entry in edited.entries where observed.entries.first(where:{$0.id==entry.id}) != entry { try sync.change(entry,deleted:false,replica:id) }
            var result=try sync.materialized();result.synchronization=sync;try write(result);return result
        }
    }
    public func syncSnapshot() throws -> PersonalLexiconSync {
        try locked {
            let current=try load();let sync=try state(current,replica:replica())
            if current.synchronization == nil { var migrated=try sync.materialized();migrated.synchronization=sync;try write(migrated) }
            return sync
        }
    }
    @discardableResult public func mergeSynchronized(_ incoming:PersonalLexiconSync) throws -> PersonalLexicon {
        try incoming.validate()
        return try locked {
            let current=try load();var sync=try state(current,replica:replica());try sync.merge(incoming)
            var result=try sync.materialized();result.synchronization=sync
            if result != current { try write(result) }
            return result
        }
    }
}
