import Foundation
import XCTest
import PrivateInputKit

final class PersonalDataResetTests:XCTestCase {
    func testUpgradeWithoutDepartureDoesNotEraseExistingWords() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("Linghe-reset-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        let word=base.appendingPathComponent("nine-choice-memory-v3.json");try Data("synthetic-existing".utf8).write(to:word)
        try PersonalDataReset.applyLocal(base:base,epoch:"initial",shared:nil)
        XCTAssertEqual(try String(contentsOf:word),"synthetic-existing")
    }
    func testConfirmedDepartureResetsOnlyOwnedPersonalDataAndBlocksStaleWriters() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("Linghe-reset-"+UUID().uuidString),shared=base.appendingPathComponent("Group")
        try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        for name in ["Rime/words.userdb/CURRENT","nine-choice-memory-v3.json","learning-checkpoint-v1.json","public-resource.txt"] {
            let url=base.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("synthetic".utf8).write(to:url)
        }
        let stale=SharedLearningSnapshot(directory:shared),epoch=UUID().uuidString
        try Data(epoch.utf8).write(to:shared.appendingPathComponent(PersonalDataReset.marker))
        try Data("synthetic".utf8).write(to:shared.appendingPathComponent("personal-lexicon-v1.json"))
        try PersonalDataReset.applyLocal(base:base,epoch:epoch,shared:shared)
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.appendingPathComponent("Rime").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:shared.appendingPathComponent("personal-lexicon-v1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:base.appendingPathComponent("public-resource.txt").path))
        XCTAssertThrowsError(try stale.publish(LearningModel().export(),by:.containingApp))
        XCTAssertFalse(PersonalDataReset.needsApply(base:base,epoch:epoch))
    }
}
