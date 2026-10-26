import XCTest
@testable import PrivateInputKit

final class CloudPersonalRecordsTests:XCTestCase {
    func testOnlyUnacknowledgedRecordsArePending() throws {
        let replica=UUID(),word=PersonalLexicon.Entry(kind:.word,text:"合成词条",trigger:"he cheng ci tiao")
        var sync=PersonalLexiconSync();try sync.change(word,deleted:false,replica:replica)
        var progress=CloudPersonalProgress(scope:"s")
        let first=try progress.pending(sync);XCTAssertEqual(first.map(\.id),[word.id.uuidString])
        progress.acked[word.id.uuidString]=try CloudPersonalProgress.digest(first[0].record)
        XCTAssertTrue(try progress.pending(sync).isEmpty)
        var edited=word;edited.text="离线修改";try sync.change(edited,deleted:false,replica:replica)
        XCTAssertEqual(try progress.pending(sync).first?.entry.text,"离线修改")
    }
    func testServerRowsMergeAsCRDTAndRoundTripWireShape() throws {
        let a=UUID(),b=UUID(),phrase=PersonalLexicon.Entry(kind:.phrase,text:"第一行\n第二行",trigger:"dz")
        var local=PersonalLexiconSync();try local.change(phrase,deleted:false,replica:a)
        var remote=local;try remote.change(phrase,deleted:true,replica:b)
        let rows=remote.records.map{CloudPersonalRecord(id:$0.key,record:$0.value)}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let wire=try JSONSerialization.jsonObject(with:encoder.encode(rows[0])) as! [String:Any]
        XCTAssertEqual(Set(wire.keys),["id","entry","deleted","revision","created"])
        XCTAssertEqual(try JSONDecoder().decode(CloudPersonalRecord.self,from:encoder.encode(rows[0])),rows[0])
        try local.merge(CloudPersonalProgress.incoming(rows))
        XCTAssertTrue(try local.materialized().entries.isEmpty)
    }
    func testMismatchedRowIdentifierIsRejected() throws {
        var sync=PersonalLexiconSync();try sync.change(.init(kind:.word,text:"词",trigger:"ci"),deleted:false,replica:UUID())
        let record=sync.records.values.first!
        XCTAssertThrowsError(try CloudPersonalProgress.incoming([CloudPersonalRecord(id:UUID().uuidString,record:record)]))
    }
}
