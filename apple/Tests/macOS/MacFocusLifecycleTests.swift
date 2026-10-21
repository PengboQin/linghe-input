import Foundation
import XCTest

final class MacFocusLifecycleTests:XCTestCase {
    func testFocusCallbacksDoNotBeginNativeAndRequireStableHiddenCooldown() {
        var gate=MacHiddenCheckpointGate();let owner=UUID()
        gate.activate(owner)
        XCTAssertFalse(gate.canPrepare(gate.ticket,now:100,nativeSessions:0))
        XCTAssertFalse(gate.nativeRunning)
        gate.deactivate(owner,now:100);let token=gate.ticket
        XCTAssertFalse(gate.canPrepare(token,now:114.999,nativeSessions:0))
        XCTAssertTrue(gate.canPrepare(token,now:115,nativeSessions:0))
        XCTAssertFalse(gate.canPrepare(token,now:115,nativeSessions:1))
        XCTAssertFalse(gate.canPrepare(token,now:99,nativeSessions:0))
    }
    func testRapidFocusSwitchesCancelOnlyQueuedGenerationAndKeepDirty() {
        var gate=MacHiddenCheckpointGate();let owner=UUID();var old:[MacHiddenCheckpointGate.Ticket]=[]
        gate.changed();let dirty=gate.dirty
        for n in 0..<50 {
            gate.activate(owner);gate.deactivate(owner,now:Double(n));old.append(gate.ticket)
        }
        for token in old.dropLast() {XCTAssertFalse(gate.canPrepare(token,now:100,nativeSessions:0))}
        XCTAssertEqual(gate.dirty,dirty);XCTAssertEqual(gate.completedDirty,0)
        XCTAssertTrue(gate.canPrepare(gate.ticket,now:64,nativeSessions:0))
    }
    func testEveryControllerMustBeInactiveAndNativeMustBeExclusive() {
        var gate=MacHiddenCheckpointGate();let a=UUID(),b=UUID()
        gate.activate(a);gate.activate(b);gate.deactivate(a,now:1)
        XCTAssertFalse(gate.canPrepare(gate.ticket,now:100,nativeSessions:0))
        gate.deactivate(b,now:100);let token=gate.ticket
        XCTAssertFalse(gate.canPrepare(token,now:114,nativeSessions:0))
        XCTAssertTrue(gate.canPrepare(token,now:115,nativeSessions:0))
        XCTAssertFalse(gate.beginNative(token,nativeSessions:0))
        XCTAssertFalse(gate.beginNative(token,nativeSessions:2))
        XCTAssertTrue(gate.beginNative(token,nativeSessions:1))
        XCTAssertFalse(gate.beginNative(token,nativeSessions:1))
        XCTAssertFalse(gate.canPrepare(token,now:200,nativeSessions:0))
        gate.endedNative();XCTAssertFalse(gate.nativeRunning)
    }
    func testCleanFingerprintSkipsExportAndNewNativeOrExternalStateDoesNot() {
        var gate=MacHiddenCheckpointGate();let owner=UUID()
        gate.deactivate(owner,now:0);var token=gate.ticket
        XCTAssertTrue(gate.needsCheckpoint(token,fingerprint:"scope-a",pending:false))
        XCTAssertTrue(gate.beginNative(token,nativeSessions:1));gate.endedNative()
        gate.completed(token,fingerprint:"scope-a")
        XCTAssertFalse(gate.needsCheckpoint(token,fingerprint:"scope-a",pending:false))
        gate.activate(owner);gate.deactivate(owner,now:20);token=gate.ticket
        XCTAssertFalse(gate.needsCheckpoint(token,fingerprint:"scope-a",pending:false))
        XCTAssertTrue(gate.needsCheckpoint(token,fingerprint:"scope-b",pending:false))
        XCTAssertTrue(gate.needsCheckpoint(token,fingerprint:nil,pending:false))
        XCTAssertTrue(gate.needsCheckpoint(token,fingerprint:"scope-a",pending:true))
        gate.changed();XCTAssertTrue(gate.needsCheckpoint(token,fingerprint:"scope-a",pending:false))
    }
    func testActivationDuringReadOnlyPreparationRejectsLatePublication() {
        var gate=MacHiddenCheckpointGate();let owner=UUID()
        gate.deactivate(owner,now:0);let old=gate.ticket
        gate.activate(owner)
        XCTAssertFalse(gate.current(old));XCTAssertFalse(gate.beginNative(old,nativeSessions:1))
        gate.completed(old,fingerprint:"late")
        XCTAssertNil(gate.externalFingerprint);XCTAssertEqual(gate.completedDirty,0)
    }
    func testAlreadyStartedNativeWorkIsNotMarkedCancelledOrCleanByReactivation() {
        var gate=MacHiddenCheckpointGate();let owner=UUID()
        gate.deactivate(owner,now:0);let old=gate.ticket
        XCTAssertTrue(gate.beginNative(old,nativeSessions:1))
        gate.activate(owner)
        XCTAssertTrue(gate.nativeRunning,"No cancellation of already-started native work")
        gate.completed(old,fingerprint:"late")
        XCTAssertEqual(gate.completedDirty,0)
        gate.endedNative();XCTAssertFalse(gate.nativeRunning)
        gate.deactivate(owner,now:100)
        XCTAssertTrue(gate.needsCheckpoint(gate.ticket,fingerprint:"late",pending:false))
    }
    func testMaintenanceDoesNotManufactureNewDirtyGeneration() {
        var gate=MacHiddenCheckpointGate();let owner=UUID()
        gate.deactivate(owner,now:0);let token=gate.ticket,dirty=gate.dirty
        XCTAssertTrue(gate.beginNative(token,nativeSessions:1));gate.endedNative()
        gate.completed(token,fingerprint:"same")
        XCTAssertEqual(gate.dirty,dirty);XCTAssertEqual(gate.completedDirty,dirty)
        gate.activate(owner);gate.deactivate(owner,now:20)
        XCTAssertFalse(gate.needsCheckpoint(gate.ticket,fingerprint:"same",pending:false))
        gate.changed();let changed=gate.dirty
        gate.completed(token,fingerprint:"stale")
        XCTAssertEqual(gate.dirty,changed)
        XCTAssertTrue(gate.needsCheckpoint(gate.ticket,fingerprint:"same",pending:false))
    }
}
