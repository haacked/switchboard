import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images that a message carries. A client reads the image, and sbd keeps a
/// copy in the session's attachments folder. The message ends with a line of
/// the copies' paths, which Claude Code attaches when they arrive as a paste
/// of their own.
public enum Attachments {
  public static let limit = 20 * 1024 * 1024
  public static let extensions = Set(Kind.allCases.map(\.rawValue)).union(["jpg"])

  public enum Kind: String, CaseIterable, Sendable {
    case png, jpeg, gif, webp, heic

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
  }

  /// The image kind that the data's first bytes name, or nil.
  public static func kind(of data: Data) -> Kind? {
    let b = [UInt8](data.prefix(12))
    func ascii(_ range: Range<Int>) -> String? {
      b.count >= range.upperBound ? String(bytes: b[range], encoding: .ascii) : nil
    }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
    if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
    if ascii(0..<6) == "GIF87a" || ascii(0..<6) == "GIF89a" { return .gif }
    if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return .webp }
    let heifBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
    if ascii(4..<8) == "ftyp", let brand = ascii(8..<12), heifBrands.contains(brand) { return .heic }
    return nil
  }

  /// One image of a `send` request.
  public static func json(name: String, data: Data) -> JSON {
    ["name": .string(name), "data": .string(data.base64EncodedString())]
  }

  private static func tooLarge(_ name: String) -> APIError {
    APIError("\(name) is larger than \(limit / 1024 / 1024) MB.")
  }

  /// Checks the name's extension, the size, and the content.
  public static func validate(name: String, data: Data) throws -> Kind {
    guard data.count <= limit else { throw tooLarge(name) }
    let ext = (name as NSString).pathExtension.lowercased()
    guard extensions.contains(ext), let kind = kind(of: data) else { throw APIError("\(name) isn't an image.") }
    return kind
  }

  /// Reads an image file. It refuses a symlink, anything but a regular file,
  /// and a file over the limit before reading it. O_NONBLOCK keeps a FIFO from
  /// blocking the open.
  public static func read(path: String) throws -> Data {
    let name = (path as NSString).lastPathComponent
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else {
      if errno == ELOOP { throw APIError("\(name) is a symlink.") }
      throw APIError("can't read \(name): \(UnixSocket.errnoText())")
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw APIError("can't read \(name): \(UnixSocket.errnoText())") }
    guard info.st_mode & S_IFMT == S_IFREG else { throw APIError("\(name) isn't an image.") }
    guard info.st_size <= limit else { throw tooLarge(name) }
    let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    _ = try validate(name: name, data: data)
    return data
  }

  /// Converts a HEIC image to PNG. Claude Code does not attach HEIC files.
  /// The PNG's pixels are upright. A camera HEIC stores a portrait photo as
  /// landscape pixels and an orientation, and the model reads only pixels.
  public static func png(fromHEIC data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    else { throw APIError("can't read the HEIC image.") }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
      throw APIError("can't convert the HEIC image.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw APIError("can't convert the HEIC image.") }
    return out as Data
  }

  /// The text, then a line of the paths. A space in a path is escaped, as a
  /// terminal escapes a dropped file's path.
  public static func message(text: String, paths: [String]) -> String {
    let line = paths.map { $0.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty { return text }
    return text.isEmpty ? line : "\(text)\n\(line)"
  }

  /// The message's text, with the new line that ends it, and its last line,
  /// when every path on that line is in `folder`. Otherwise nil.
  public static func split(_ message: String, folder: String) -> (text: String, paths: String)? {
    let cut = message.lastIndex(of: "\n").map { message.index(after: $0) } ?? message.startIndex
    let line = String(message[cut...])
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    let paths = unescapedPaths(line)
    let inside = { (path: String) in path.hasPrefix(prefix) && !path.split(separator: "/").contains("..") }
    guard !paths.isEmpty, paths.allSatisfy(inside) else { return nil }
    return (String(message[..<cut]), line)
  }

  /// Splits the line at each space that no backslash escapes.
  private static func unescapedPaths(_ line: String) -> [String] {
    var paths: [String] = []
    var current = ""
    var escaped = false
    for c in line {
      if escaped {
        current.append(c)
        escaped = false
      } else if c == "\\" {
        escaped = true
      } else if c == " " {
        if !current.isEmpty { paths.append(current) }
        current = ""
      } else {
        current.append(c)
      }
    }
    if !current.isEmpty { paths.append(current) }
    return paths
  }
}
