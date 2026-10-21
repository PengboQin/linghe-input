import XCTest
@testable import PrivateInputKit

final class PersonalLexiconSyncTests:XCTestCase {
    func testNewMemberReceivesUnchangedCumulativeSnapshotAndNewGroupCannotReuseOldPublication() {
        let digest=Data([1,2,3]),group=UUID()
        XCTAssertFalse(LearningPublication.needed(digest:digest,group:group,epoch:2,previousDigest:digest,previousGroup:group,previousEpoch:2))
        XCTAssertTrue(LearningPublication.needed(digest:digest,group:group,epoch:3,previousDigest:digest,previousGroup:group,previousEpoch:2))
        XCTAssertTrue(LearningPublication.needed(digest:digest,group:UUID(),epoch:2,previousDigest:digest,previousGroup:group,previousEpoch:2))
        XCTAssertTrue(LearningPublication.needed(digest:digest,group:group,epoch:2,previousDigest:digest,previousGroup:nil,previousEpoch:nil))
    }
    func testOfflineEditsAndDeleteConvergeWithoutResurrection() throws {
        let a=UUID(),b=UUID(),word=PersonalLexicon.Entry(kind:.word,text:"合成词条",trigger:"he cheng ci tiao")
        var initial=PersonalLexiconSync();try initial.change(word,deleted:false,replica:a)
        var left=initial,right=initial,edited=word;edited.text="离线修改"
        try left.change(edited,deleted:false,replica:a);try right.change(word,deleted:true,replica:b)
        var x=left,y=right;try x.merge(right);try y.merge(left)
        XCTAssertEqual(x,y);XCTAssertTrue(try x.materialized().entries.isEmpty)
        try x.merge(initial);XCTAssertTrue(try x.materialized().entries.isEmpty)
        try x.change(edited,deleted:false,replica:a);try y.merge(x)
        XCTAssertEqual(try y.materialized().entries,[edited])
    }
    func testIndependentOfflineEntriesAndAliasesRemainDeterministic() throws {
        var a=PersonalLexiconSync(),b=PersonalLexiconSync()
        let replicaA=UUID(),replicaB=UUID()
        let one=PersonalLexicon.Entry(kind:.phrase,text:"测试短语",trigger:"cs")
        let two=PersonalLexicon.Entry(kind:.phrase,text:"测试短语",trigger:"cs")
        try a.change(one,deleted:false,replica:replicaA);try b.change(two,deleted:false,replica:replicaB)
        try a.merge(b);try b.merge(a);XCTAssertEqual(a,b)
        let visible=try XCTUnwrap(a.materialized().entries.first)
        XCTAssertEqual(try a.materialized().entries.count,1)
        try a.change(visible,deleted:true,replica:replicaA);try b.merge(a)
        XCTAssertTrue(try b.materialized().entries.isEmpty)
    }
    func testLegacyMigrationAndStaleSheetDoNotOverwriteRemoteAddition() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store=PersonalLexiconStore(directory:directory),word=PersonalLexicon.Entry(kind:.word,text:"旧词",trigger:"jiu ci")
        var old=PersonalLexicon();try old.upsert(word)
        try JSONEncoder().encode(old).write(to:store.url)
        let observed=try store.load();let local=try store.syncSnapshot()
        XCTAssertEqual(try store.load().entries,[word])
        var remote=local
        let phrase=PersonalLexicon.Entry(kind:.phrase,text:"另一设备新增",trigger:"xz")
        try remote.change(phrase,deleted:false,replica:UUID());_ = try store.mergeSynchronized(remote)
        var edited=observed,changed=word;changed.text="本机编辑";try edited.upsert(changed)
        let saved=try store.applying(observed:observed,edited:edited)
        XCTAssertEqual(Set(saved.entries.map(\.id)),[word.id,phrase.id])
        XCTAssertEqual(saved.entries.first(where:{$0.id==word.id})?.text,"本机编辑")
        XCTAssertEqual(try store.syncSnapshot(),saved.synchronization)
    }
    func testLearningWireAndPersistentModelKeepExplicitEntries() throws {
        var personal=PersonalLexiconSync();try personal.change(.init(kind:.phrase,text:"多行\n合成短语",trigger:"dh"),deleted:false,replica:UUID())
        var learning=LearningModel();try learning.record(reading:"ni hao",text:"你好",device:"fixture")
        let legacy=try learning.export();try learning.mergePersonalLexicon(personal)
        var received=LearningModel();try received.merge(learning.export());try received.merge(legacy)
        XCTAssertEqual(received.personalLexicon,personal)
        let restored=try JSONDecoder().decode(LearningModel.self,from:JSONEncoder().encode(received))
        XCTAssertEqual(restored.personalLexicon,personal)
        let oldStored=Data("{\"entries\":{},\"learningEnabled\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(LearningModel.self,from:oldStored).personalLexicon)
    }
    func testInvalidRemoteIsRejectedAtomically() throws {
        var original=PersonalLexiconSync();try original.change(.init(kind:.phrase,text:"保留",trigger:"bl"),deleted:false,replica:UUID())
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as? [String:Any])
        json["version"]=99
        let bad=try JSONDecoder().decode(PersonalLexiconSync.self,from:JSONSerialization.data(withJSONObject:json))
        var target=original;XCTAssertThrowsError(try target.merge(bad));XCTAssertEqual(target,original)
    }
}
