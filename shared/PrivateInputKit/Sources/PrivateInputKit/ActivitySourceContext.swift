import Foundation

/// Describes only the source the provider can identify. It never contains a
/// window title, executable path, nearby text, URL, or guessed iOS host app.
public struct ActivitySourceContext: Equatable {
    public static let extensionKey = "org.linghe.context.v1"
    public let fields: [String: String]

    public init(platform: String, sourceAppID: String? = nil, sourceAppName: String? = nil,
                inputMethodVersion: String? = nil, inputMethodBuild: String? = nil,
                fieldType: String? = nil, returnKey: String? = nil, layout: String? = nil,
                captureComponent: String = "input_method") {
        let identifier = Self.bounded(sourceAppID, bytes: 256).flatMap {
            $0.contains("/") || $0.contains("\\") ? nil : $0
        }
        // A display name is meaningful only when bound to an identified host.
        let name = identifier == nil ? nil : Self.bounded(sourceAppName, bytes: 256)
        var value = ["platform": Self.bounded(platform, bytes: 24) ?? "unknown",
                     "app_identity_status": identifier == nil ? "unavailable" : name == nil ? "identifier_only" : "available",
                     "capture_component": Self.bounded(captureComponent, bytes: 48) ?? "unknown"]
        if let identifier { value["source_app_id"] = identifier }
        if let name { value["source_app_name"] = name }
        for (key, candidate) in [("input_method_version", inputMethodVersion), ("input_method_build", inputMethodBuild),
                                 ("field_type", fieldType), ("return_key", returnKey), ("layout", layout)] {
            value[key] = Self.bounded(candidate, bytes: 64) ?? "unavailable"
        }
        fields = value
    }

    private static func bounded(_ value: String?, bytes: Int) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= bytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
}
