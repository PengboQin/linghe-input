import Foundation
import CryptoKit

public enum ClipboardLiveHTTPError:Error {case status(Int,String)}

public struct ClipboardLiveClient {
    private let endpoint:URL
    public init(endpoint:URL,allowLoopbackHTTP:Bool=false)throws {self.endpoint=try RelayClient(endpoint:endpoint,allowLoopbackHTTP:allowLoopbackHTTP).endpoint}
    private func request(_ operation:String,body:Data?=nil)throws->URLRequest {
        var u=endpoint;for part in ["clipboard-live","v1",operation] {u.appendPathComponent(part)}
        var r=URLRequest(url:u,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:10)
        r.httpMethod=body==nil ? "GET":"POST";r.httpBody=body
        r.setValue("application/json",forHTTPHeaderField:"Accept")
        if body != nil {r.setValue("application/json",forHTTPHeaderField:"Content-Type")};return r
    }
    private func send(_ request:URLRequest,maximum:Int)async throws->Data {
        let s=PrivateInputHTTPSessions.clipboard
        let (bytes,response)=try await s.bytes(for:request)
        guard let http=response as? HTTPURLResponse else {throw ClipboardLiveError.invalid}
        if http.statusCode==404 {throw ClipboardLiveError.unavailable}
        let bound=http.statusCode==200 ? maximum:4096
        guard response.expectedContentLength<=bound else {throw ClipboardLiveError.quota}
        var data=Data();for try await byte in bytes {try Task.checkCancellation();guard data.count<bound else {throw ClipboardLiveError.quota};data.append(byte)}
        guard http.statusCode==200 else {
            let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let error=value?["error"] as? String ?? "request_failed"
            let reason=error.count<=80 && error.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="_")}) ? error:"request_failed"
            throw ClipboardLiveHTTPError.status(http.statusCode,reason)
        }
        return data
    }
    public func supported()async throws->Bool {
        struct Status:Decodable {let version:Int,supported:Bool}
        let r=try await send(request("status"),maximum:4096),s=try JSONDecoder().decode(Status.self,from:r);return s.version==1 && s.supported
    }
    public func batch(_ snapshot:ClipboardLiveSnapshot,now:UInt64)async throws->ClipboardLiveResponse {
        try snapshot.configuration.validate(now:now)
        let c=snapshot.configuration,b=ClipboardLiveBatch(after:snapshot.cursor ?? 0,publish:snapshot.pending.first?.envelope)
        let body=try JSONEncoder().encode(b),delegate=try Curve25519.Signing.PrivateKey(rawRepresentation:c.delegatePrivate)
        let signed=try ClipboardLiveRequest.signed(certificate:c.certificate,delegate:delegate,body:body,now:now)
        let data=try await send(request("batch",body:JSONEncoder().encode(signed)),maximum:1024*1024)
        let result=try JSONDecoder().decode(ClipboardLiveResponse.self,from:data);try result.validate(after:b.after)
        guard result.accepted==b.publish?.event else {throw ClipboardLiveError.invalid};return result
    }
    public func revoke(_ value:ClipboardLiveRevocation)async throws {
        struct Reply:Decodable {let version:Int,revoked:Bool,generation:UUID}
        let data=try await send(request("revoke",body:JSONEncoder().encode(value)),maximum:4096),reply=try JSONDecoder().decode(Reply.self,from:data)
        guard reply.version==1,reply.revoked,reply.generation==value.generation else {throw ClipboardLiveError.invalid}
    }
}
