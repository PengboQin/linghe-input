import Foundation

/// Per-device desktop presentation. It never changes candidate scores or syncs
/// with learned words. Windows uses the same bounded fields in its adapter.
public struct DesktopCandidateLayout:Codable,Equatable {
    public static let allowed=3...9
    public let collapsedCount:Int
    public let expandedColumns:Int
    public let expandedRows:Int
    public init(collapsedCount:Int=6,expandedColumns:Int=6,expandedRows:Int=6) {
        func bounded(_ value:Int)->Int {max(Self.allowed.lowerBound,min(Self.allowed.upperBound,value))}
        self.collapsedCount=bounded(collapsedCount);self.expandedColumns=bounded(expandedColumns);self.expandedRows=bounded(expandedRows)
    }
    public var pageSize:Int {expandedColumns*expandedRows}
    public func columns(expanded:Bool)->Int {expanded ? expandedColumns:collapsedCount}
    private enum CodingKeys:String,CodingKey {case collapsedCount,expandedColumns,expandedRows}
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        self.init(collapsedCount:try values.decodeIfPresent(Int.self,forKey:.collapsedCount) ?? 6,expandedColumns:try values.decodeIfPresent(Int.self,forKey:.expandedColumns) ?? 6,expandedRows:try values.decodeIfPresent(Int.self,forKey:.expandedRows) ?? 6)
    }
}
