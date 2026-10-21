import XCTest
import CryptoKit
@testable import PrivateInputKit
final class QuickPairingTests:XCTestCase {
    func testQRRoundTripExpiryAndMalformedPayload() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("QuickPair-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let vault=try DeviceIdentityVault(store:SyntheticIdentityStore(),directory:directory)
        let identity=try vault.create(),group=try GroupSetup.create(owner:identity)
        let invitation=DeviceInvitation(endpoint:URL(string:"https://sync.example.invalid")!,anchor:group.membership.anchor)
        let qr=QuickPairQR(invitation:invitation,ticket:UUID(),secret:Data(repeating:42,count:32),expiresAt:1300)
        let link=try qr.link(),decoded=try QuickPairQR.decode(link,now:1000)
        XCTAssertEqual(decoded.ticket,qr.ticket);XCTAssertEqual(decoded.secret,qr.secret);XCTAssertEqual(decoded.invitation.anchor,invitation.anchor)
        XCTAssertThrowsError(try QuickPairQR.decode(link,now:1300))
        XCTAssertThrowsError(try QuickPairQR.decode(link,now:999))
        XCTAssertThrowsError(try QuickPairQR.decode(URL(string:"https://example.invalid/?data=abc")!,now:1000))
        XCTAssertThrowsError(try QuickPairQR(invitation:invitation,ticket:UUID(),secret:Data(),expiresAt:1300).link())
    }
}
