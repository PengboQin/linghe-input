import XCTest
@testable import PrivateInputKit

final class PersonalLexiconTests:XCTestCase {
    func testNormalizedEntriesMatchBothLayoutsAndRespectExplicitSyllables() throws {
        var value=PersonalLexicon()
        try value.upsert(.init(kind:.word,text:"拟好",trigger:" NI ' HAO "),syllables:["ni","hao"])
        try value.upsert(.init(kind:.word,text:"米好",trigger:"mi hao"),syllables:["ni","mi","hao"])
        XCTAssertEqual(value.matches(input:"nihao",nineKey:false).map(\.text),["拟好"])
        XCTAssertEqual(value.matches(input:"64426",nineKey:true).count,2)
        XCTAssertEqual(value.matches(input:"ni'426",nineKey:true).map(\.text),["拟好"])
        XCTAssertEqual(value.matches(input:"mi'hao'",nineKey:true).map(\.text),["米好"])
        XCTAssertTrue(value.matches(input:"644",nineKey:true).isEmpty)
        XCTAssertTrue(value.matches(input:"nih",nineKey:false).isEmpty)
    }
    func testInvalidAndDuplicateEntryEditsAreAtomic() throws {
        var value=PersonalLexicon();let entry=PersonalLexicon.Entry(kind:.word,text:"拟好",trigger:"ni hao")
        try value.upsert(entry,syllables:["ni","hao"]);let before=value
        XCTAssertThrowsError(try value.upsert(.init(kind:.word,text:"坏音",trigger:"xxxx"),syllables:["ni","hao"]))
        XCTAssertEqual(value,before)
        XCTAssertThrowsError(try value.upsert(.init(kind:.word,text:"拟好",trigger:"ni hao")))
        XCTAssertThrowsError(try value.upsert(.init(kind:.phrase,text:"bad\0record",trigger:"dz")))
        XCTAssertEqual(value,before)
        var edited=entry;edited.text="你好";try value.upsert(edited);XCTAssertEqual(value.entries.count,1)
        value.remove(id:entry.id);XCTAssertTrue(value.entries.isEmpty)
    }
    func testPhraseIsExplicitExactTriggerAndSupportsMultipleLines() throws {
        var value=PersonalLexicon();try value.upsert(.init(kind:.phrase,text:"合成地址\n请先联系",trigger:"DZ"))
        XCTAssertEqual(value.matches(input:"dz",nineKey:false).first?.text,"合成地址\n请先联系")
        XCTAssertEqual(value.matches(input:"39",nineKey:true).count,1)
        XCTAssertTrue(value.matches(input:"3",nineKey:true).isEmpty)
        XCTAssertTrue(value.matches(input:"d'z'",nineKey:true).isEmpty)
    }
    func testImportMergeKeepsLocalEditsAndRejectsInvalidWholeArchive() throws {
        var local=PersonalLexicon(),incoming=PersonalLexicon()
        let entry=PersonalLexicon.Entry(kind:.phrase,text:"本机编辑",trigger:"bd")
        try local.upsert(entry)
        var old=entry;old.text="旧内容";try incoming.upsert(old)
        try incoming.upsert(.init(kind:.phrase,text:"另一条",trigger:"lt"))
        try local.merge(incoming);XCTAssertEqual(local.entries.count,2);XCTAssertEqual(local.entries.first,entry)
        try local.merge(incoming);XCTAssertEqual(local.entries.count,2)
        let before=local;incoming.version=99
        XCTAssertThrowsError(try local.merge(incoming));XCTAssertEqual(local,before)
    }
    func testStoreRoundTripAndDamagedArchiveNeverOverwritten() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=PersonalLexiconStore(directory:directory);XCTAssertTrue(try store.load().entries.isEmpty)
        var value=PersonalLexicon();try value.upsert(.init(kind:.word,text:"拟好",trigger:"ni hao"));try store.save(value)
        XCTAssertEqual(try store.load().entries,value.entries);XCTAssertNotNil(try store.load().synchronization)
        let bad=Data("broken archive".utf8);try bad.write(to:store.url)
        XCTAssertThrowsError(try store.save(PersonalLexicon()));XCTAssertEqual(try Data(contentsOf:store.url),bad)
        XCTAssertThrowsError(try PersonalLexiconStore.decode(Data(repeating:0,count:PersonalLexicon.maximumBytes+1)))
    }
    func testRecallBudgetIncludesMiddleDictionaryRanksAndRetainsBounds() {
        let legacy=(0..<64).map{(input:"legacy\($0)",cost:1.0)}
        let dictionary=(0..<12).map{(input:"dictionary\($0)",cost:1.5)}
        let queries=NineKeySentencePlanner.recallQueries(legacy:legacy,dictionary:[dictionary])
        XCTAssertEqual(queries.count,48);XCTAssertEqual(queries.prefix(2).map(\.input),["dictionary0","dictionary1"])
        XCTAssertTrue(Set(dictionary.map(\.input)).isSubset(of:Set(queries.map(\.input))))
        XCTAssertEqual(Set(queries.map(\.input)).count,queries.count)
        XCTAssertTrue(NineKeySentencePlanner.recallQueries(legacy:legacy,dictionary:[dictionary],limit:0).isEmpty)
    }
}
