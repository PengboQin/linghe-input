import Foundation
// System-menu representation derived from the approved app artwork.
guard CommandLine.arguments.count == 2 else { fatalError("Output TIFF path required") }
let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = script.deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("design/brand/input-source-icon.tiff")
let data = try Data(contentsOf: master)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
