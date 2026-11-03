import Foundation
import CoreGraphics
import ImageIO

enum IconFailure: Error { case invalid(String) }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw IconFailure.invalid(message) }
}
func raster(_ data: Data) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw IconFailure.invalid("Unreadable icon PNG") }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IconFailure.invalid("Unable to decode pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, pixels)
}
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let master = try raster(Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icon/Assets/Recall.png")))
try require(master.width == 1024 && master.height == 1024, "The icon master must be 1024 square")
try require(stride(from: 3, to: master.pixels.count, by: 4).allSatisfy { master.pixels[$0] == 255 }, "Modern artwork must be opaque and full bleed")
let data = try Data(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))
func number(_ offset: Int) -> Int { data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
try require(data.count >= 8 && String(decoding: data.prefix(4), as: UTF8.self) == "icns" && number(4) == data.count, "Invalid ICNS header")
let expected = ["icp4": 16, "icp5": 32, "icp6": 64, "ic07": 128, "ic08": 256, "ic09": 512,
    "ic10": 1024, "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512]
var offset = 8, found = Set<String>()
while offset < data.count {
    try require(offset + 8 <= data.count, "Truncated ICNS entry")
    let kind = String(decoding: data[offset..<offset + 4], as: UTF8.self), length = number(offset + 4)
    try require(length > 8 && offset + length <= data.count, "Invalid ICNS entry length")
    guard let size = expected[kind] else { throw IconFailure.invalid("Unexpected ICNS representation") }
    try require(found.insert(kind).inserted, "Duplicate ICNS representation")
    let image = try raster(data.subdata(in: offset + 8..<offset + length))
    try require(image.width == size && image.height == size, "Wrong representation size: \(kind)")
    func alpha(_ x: Int, _ y: Int) -> UInt8 { image.pixels[(y * size + x) * 4 + 3] }
    try require(alpha(size / 2, size / 2) == 255, "Translucent icon body: \(kind)")
    try require(alpha(0, 0) == 0 && alpha(size - 1, size - 1) == 0, "Opaque outer container: \(kind)")
    if size == 1024 {
        for y in 0..<size { for x in 0..<size where x < 40 || y < 40 || x > 984 || y > 984 {
            try require(alpha(x, y) == 0, "Stray pixels outside the standard enclosure")
        } }
        try require(alpha(100, 512) == 255 && alpha(924, 512) == 255, "Icon has excessive internal margins")
    }
    offset += length
}
try require(found == Set(expected.keys), "Missing icon resolutions")
print("PASS: opaque full-bleed modern icon and 11 legacy representations, with clean enclosure, balanced margins and opaque interior")
