import Foundation

/// Explicit symbol selections only. No host text, timestamps or identifiers.
public struct SymbolUsage: Codable {
    public var version = 1
    public private(set) var counts: [String: Int] = [:]
    public init() {}
    public func validate() throws {
        guard version == 1, counts.count <= 512,
              counts.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 32 && (1...1_000_000).contains($0.value) }) else {
            throw InputDataError.invalidRecord
        }
    }
    public mutating func record(_ symbol: String, allowed: Set<String>) {
        guard allowed.contains(symbol), !symbol.isEmpty, symbol.utf8.count <= 32,
              counts[symbol] != nil || counts.count < 512 else { return }
        counts[symbol] = min(1_000_000, (counts[symbol] ?? 0) + 1)
    }
    public func ordered(seed: [String], catalog: [String], limit: Int = 64) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        let values = (seed + catalog.filter { counts[$0] != nil }).filter { seen.insert($0).inserted }
        return values.enumerated().sorted {
            let a = counts[$0.element] ?? 0, b = counts[$1.element] ?? 0
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(min(limit, 128)).map(\.element)
    }
}
