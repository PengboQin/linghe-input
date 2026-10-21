import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Public hardware description, never serial numbers, MAC addresses or hostnames.
public enum ActivityDeviceDescription {
    public static let extensionKey = "org.linghe.device.v1"
    public static let fields: [String: ActivityJSONValue] = {
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        var model = "unavailable"
        #if canImport(Darwin)
        var size = 0
        if sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0, size < 256 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 { model = String(cString: bytes) }
        }
        #if os(macOS)
        size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 { model = String(cString: bytes) }
        }
        #endif
        #endif
        return ["platform": .string(platform), "brand": .string("Apple"),
                "device_type": .string(platform == "macos" ? "computer":model.hasPrefix("iPad") ? "tablet":model.hasPrefix("iPhone") ? "phone":"unavailable"), "model": .string(model), "os_version": .string(ProcessInfo.processInfo.operatingSystemVersionString)]
    }()
}

/// Optional IME-only diagnostics. It is NOT a global keyboard observer and
/// uses a separate provider consent, including when output recording is on.
public struct ActivityInputDiagnostic {
    public static let provider = "ime.diagnostic.v1"
    public static let extensionKey = "org.linghe.input.v1"
    public let text: String
    public let fields: [String: ActivityJSONValue]
    public init?(action: String, key: String, before: String, after: String, candidates: [String] = []) {
        guard ["key", "delete", "choose", "clear", "literal", "mode", "edit"].contains(action),
              key.utf8.count <= 128, before.utf8.count <= 4096, after.utf8.count <= 4096 else { return nil }
        text = after
        fields = ["action": .string(action), "key": .string(key), "raw_before": .string(before),
                  "raw_after": .string(after), "committed": .bool(false),
                  "candidate_preview": .array(candidates.prefix(5).map { .string(String($0.prefix(64))) })]
    }
}
