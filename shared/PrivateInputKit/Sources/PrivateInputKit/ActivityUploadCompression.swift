import Foundation
import zlib

/// HTTP envelope only. Event bytes and the signed request stay unchanged.
struct ActivityUploadBody: Sendable {
    let data: Data
    let contentEncoding: String?
    static func prepare(_ input: Data, negotiated: Bool) throws -> Self {
        guard input.count <= 1_048_576 else { throw ActivityError.eventTooLarge }
        guard negotiated, input.count >= 4096 else { return .init(data: input, contentEncoding: nil) }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                           MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                           Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ActivityError.storageFailure }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(input.count))))
        let result = input.withUnsafeBytes { raw -> Int32 in
            output.withUnsafeMutableBytes { destination -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw ActivityError.storageFailure }
        output.count = Int(stream.total_out)
        guard output.count + 32 < input.count else { return .init(data: input, contentEncoding: nil) }
        return .init(data: output, contentEncoding: "gzip")
    }
}

/// Per-transport capability; a new/old endpoint starts with ordinary JSON.
final class ActivityUploadNegotiation: @unchecked Sendable {
    private let lock = NSLock()
    private var gzip = false
    var supportsGzip: Bool { lock.lock(); defer { lock.unlock() }; return gzip }
    func observeStatus(_ response: Data) {
        let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        let transport = object?["transport"] as? [String: Any]
        let encodings = transport?["request_content_encodings"] as? [String] ?? []
        lock.lock(); gzip = encodings.contains("gzip"); lock.unlock()
    }
}
