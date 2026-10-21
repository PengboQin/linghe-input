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
        let data=try JSONEncoder().encode(self)
        var c=URLComponents();c.scheme="privateinput";c.host="pair"
        c.queryItems=[.init(name:"data",value:data.base64EncodedString())]
        guard let url=c.url else { throw PairingError.malformed };return url
    }
    public static func decode(_ url:URL,now:UInt64) throws -> Self {
        guard let c=URLComponents(url:url,resolvingAgainstBaseURL:false),c.scheme=="privateinput",c.host=="pair",c.user==nil,c.password==nil,c.fragment==nil,c.queryItems?.count==1,c.queryItems?.first?.name=="data",let text=c.queryItems?.first?.value,text.utf8.count<=8192,let data=Data(base64Encoded:text) else { throw PairingError.malformed }
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.secret.count==32,now<value.expiresAt,value.expiresAt-now<=300 else { throw PairingError.expired }
        _ = try value.invitation.link()
        return value
    }
}
