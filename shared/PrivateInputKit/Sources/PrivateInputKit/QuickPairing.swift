import Foundation
import CryptoKit

public struct QuickPairTicket: Codable, Equatable {
    public let ticket: UUID
    public let code: String
    public let expiresAt: UInt64
}
public struct QuickPairClaim: Decodable {
    public let ticket: UUID
    public let sponsor: UUID
    public let expiresAt: UInt64
    public let request: PairRequest
}
public struct QuickPairQR: Codable {
    public let invitation: DeviceInvitation
    public let ticket: UUID
    public let secret: Data
    public let expiresAt: UInt64
    public init(invitation:DeviceInvitation,ticket:UUID,secret:Data,expiresAt:UInt64) {
        self.invitation=invitation;self.ticket=ticket;self.secret=secret;self.expiresAt=expiresAt
    }
    public func link() throws -> URL {
        guard secret.count==32 else { throw PairingError.malformed }
        // Public application key: hides text from generic QR readers, not
        // reverse engineering. Ticket signatures remain the admission boundary.
        let encoded=try JSONEncoder().encode(self)
        let data=try AES.GCM.seal(encoded,using:Self.envelopeKey,authenticating:Self.envelopeContext).combined!
        var c=URLComponents();c.scheme="privateinput";c.host="pair"
        c.queryItems=[.init(name:"data",value:"v2:"+data.base64EncodedString())]
        guard let url=c.url else { throw PairingError.malformed };return url
    }
    private static let envelopeContext=Data("LingheInput/qr-envelope/v2".utf8)
    private static var envelopeKey:SymmetricKey {SymmetricKey(data:SHA256.hash(data:Data("LingheInput/qr-envelope/v2/public-reader-key".utf8)))}
    public static func decode(_ url:URL,now:UInt64) throws -> Self {
        guard let c=URLComponents(url:url,resolvingAgainstBaseURL:false),c.scheme=="privateinput",c.host=="pair",c.user==nil,c.password==nil,c.fragment==nil,c.queryItems?.count==1,c.queryItems?.first?.name=="data",let text=c.queryItems?.first?.value,text.utf8.count<=8192 else { throw PairingError.malformed }
        let data:Data
        if text.hasPrefix("v2:") {
            guard let box=Data(base64Encoded:String(text.dropFirst(3))) else {throw PairingError.malformed}
            data=try AES.GCM.open(AES.GCM.SealedBox(combined:box),using:envelopeKey,authenticating:envelopeContext)
        } else {
            guard let legacy=Data(base64Encoded:text) else {throw PairingError.malformed};data=legacy
        }
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.secret.count==32,now<value.expiresAt,value.expiresAt-now<=300 else { throw PairingError.expired }
        _ = try value.invitation.link()
        return value
    }
}
