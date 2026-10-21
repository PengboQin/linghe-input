import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let brand=root.appendingPathComponent("design/brand")
guard let source=CGImageSourceCreateWithURL(brand.appendingPathComponent("linghe-crane-master.png") as CFURL,nil),let artwork=CGImageSourceCreateImageAtIndex(source,0,nil) else {fatalError("Missing generated artwork")}
func png(_ path:URL,size:Int,mac:Bool=false) throws {
 let alpha=mac ? CGImageAlphaInfo.premultipliedLast:CGImageAlphaInfo.noneSkipLast
 let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:alpha.rawValue)!
 let side=CGFloat(size),canvas=CGRect(x:0,y:0,width:side,height:side)
 if mac {context.clear(canvas)} else {context.setFillColor(gray:1,alpha:1);context.fill(canvas)}
 let inset=mac ? side*0.078125:0,frame=canvas.insetBy(dx:inset,dy:inset)
 if mac {context.addPath(CGPath(roundedRect:frame,cornerWidth:side*0.185,cornerHeight:side*0.185,transform:nil));context.clip()}
 context.interpolationQuality = .high;context.draw(artwork,in:frame)
 let output=context.makeImage()!,destination=CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(destination,output,nil);precondition(CGImageDestinationFinalize(destination))
}
try png(brand.appendingPathComponent("app-icon-1024.png"),size:1024)
try png(root.appendingPathComponent("apple/iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"),size:1024)
try png(brand.appendingPathComponent("app-icon-macos-1024.png"),size:1024,mac:true)
let iconset=brand.appendingPathComponent("Linghe.iconset");try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for n in [16,32,128,256,512] {
 try png(iconset.appendingPathComponent("icon_\(n)x\(n).png"),size:n,mac:true)
 try png(iconset.appendingPathComponent("icon_\(n)x\(n)@2x.png"),size:n*2,mac:true)
}
print("Exported opaque iOS master and native Mac iconset")
