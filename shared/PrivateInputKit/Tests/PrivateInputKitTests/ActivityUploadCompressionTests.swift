import Foundation
import XCTest
import zlib
@testable import PrivateInputKit

final class ActivityUploadCompressionTests: XCTestCase {
    private func inflateGzip(_ bytes: Data, expected: Int) throws -> Data {
        var stream=z_stream()
        XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS+16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)),Z_OK)
        defer { inflateEnd(&stream) }
        var decoded=Data(count:expected+1)
        let status=bytes.withUnsafeBytes { raw in decoded.withUnsafeMutableBytes { output in
            stream.next_in=UnsafeMutablePointer(mutating:raw.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(bytes.count)
            stream.next_out=output.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(output.count)
            return inflate(&stream,Z_FINISH)
        }}
        XCTAssertEqual(status,Z_STREAM_END);XCTAssertEqual(stream.avail_in,0)
        decoded.count=Int(stream.total_out);return decoded
    }
    func testNegotiatedEnvelopeRoundTripsWithoutChangingOriginal() throws {
        let original=Data(String(repeating:"{\"event_id\":\"synthetic\",\"text\":\"中文 🦢\\n  retained\"}",count:256).utf8)
        let upload=try ActivityUploadBody.prepare(original,negotiated:true)
        XCTAssertEqual(upload.contentEncoding,"gzip");XCTAssertLessThan(upload.data.count,original.count/4)
        XCTAssertEqual(try inflateGzip(upload.data,expected:original.count),original)
        XCTAssertEqual(Array(upload.data.prefix(2)),[31,139])
        XCTAssertEqual(try ActivityUploadBody.prepare(original,negotiated:false).data,original)
    }
    func testSmallAndIncompressibleRequestsStayOrdinaryJSON() throws {
        XCTAssertNil(try ActivityUploadBody.prepare(Data("{}".utf8),negotiated:true).contentEncoding)
        var seed:UInt64=7;let random=Data((0..<8192).map { _ -> UInt8 in seed=seed &* 6364136223846793005 &+ 1;return UInt8(truncatingIfNeeded:seed>>32) })
        let upload=try ActivityUploadBody.prepare(random,negotiated:true)
        XCTAssertNil(upload.contentEncoding);XCTAssertEqual(upload.data,random)
        XCTAssertThrowsError(try ActivityUploadBody.prepare(Data(count:1_048_577),negotiated:true))
    }
    func testStatusNegotiationStartsOffAndOldServerClearsCapability() {
        let gate=ActivityUploadNegotiation();XCTAssertFalse(gate.supportsGzip)
        gate.observeStatus(Data("{\"transport\":{\"request_content_encodings\":[\"identity\",\"gzip\"]}}".utf8));XCTAssertTrue(gate.supportsGzip)
        gate.observeStatus(Data("{\"version\":1,\"operation\":1,\"result\":{}}".utf8));XCTAssertFalse(gate.supportsGzip)
    }
}
