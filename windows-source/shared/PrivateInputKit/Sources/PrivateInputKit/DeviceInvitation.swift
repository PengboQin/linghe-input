import Foundation

public struct DeviceInvitation: Codable {
    public var version: UInt8 = 1
    public let endpoint: URL
    public let anchor: MembershipAnchor
    public init(endpoint: URL, anchor: MembershipAnchor) { self.endpoint = endpoint; self.anchor = anchor }
    public func link(allowLoopbackHTTP: Bool = false) throws -> URL {
        _ = try RelayClient(endpoint: endpoint, allowLoopbackHTTP: allowLoopbackHTTP)
        guard version == 1, anchor.ownerPublic.count == 32 else { throw PairingError.malformed }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 4096 else { throw PairingError.malformed }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var parts = URLComponents(); parts.scheme = "privateinput"; parts.host = "join"
        parts.queryItems = [URLQueryItem(name: "data", value: encoded)]
        guard let url = parts.url else { throw PairingError.malformed }; return url
    }
    public static func decode(_ link: URL, allowLoopbackHTTP: Bool = false) throws -> Self {
        guard let parts = URLComponents(url: link, resolvingAgainstBaseURL: false), parts.scheme == "privateinput", parts.host == "join",
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.queryItems?.count == 1,
              parts.queryItems?[0].name == "data", let value = parts.queryItems?[0].value, value.utf8.count <= 5500 else { throw PairingError.malformed }
        var base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base), data.count <= 4096 else { throw PairingError.malformed }
        let invitation = try JSONDecoder().decode(Self.self, from: data)
        guard invitation.version == 1, invitation.anchor.ownerPublic.count == 32 else { throw PairingError.malformed }
        _ = try RelayClient(endpoint: invitation.endpoint, allowLoopbackHTTP: allowLoopbackHTTP)
        return invitation
    }
}
