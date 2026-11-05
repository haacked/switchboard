import Foundation
import SwitchboardCore

extension Service {
  /// Saves a `send` request's images in the session's attachments folder and
  /// returns a plain `send` whose text ends with their paths. It runs off the
  /// state queue. Each image arrives as its bytes, because sbd can't read the
  /// folders that macOS protects, such as ~/Desktop, where screenshots land.
  /// It keeps nothing when it refuses one image.
  func savingImages(_ request: Request) throws -> Request {
    let id = try queue.sync { try lookup(request.args) }
    guard let images = request.args["images"]?.array, !images.isEmpty else {
      throw APIError("send needs images when it names them")
    }
    let files = try images.map { image -> (name: String, data: Data) in
      guard let name = image["name"]?.string, let encoded = image["data"]?.string,
        let data = Data(base64Encoded: encoded)
      else { throw APIError("each image needs a name and base64 data") }
      let kind = try Attachments.validate(name: name, data: data)
      if kind == .heic { return (Self.attachmentName(name, ext: "png"), try Attachments.png(fromHEIC: data)) }
      return (Self.attachmentName(name, ext: kind.fileExtension), data)
    }
    let folder = home.attachmentsFolder(id)
    try FileManager.default.createDirectory(
      atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let stamp = nowMs()
    var paths: [String] = []
    do {
      for file in files { paths.append(try Self.writeNew(file.data, in: folder, name: "\(stamp)-\(file.name)")) }
    } catch {
      for path in paths { try? FileManager.default.removeItem(atPath: path) }
      throw error
    }
    var args = request.args.object ?? [:]
    args["images"] = nil
    args["session"] = .string(id)
    args["text"] = .string(Attachments.message(text: args["text"]?.string ?? "", paths: paths))
    return Request(op: "send", args: .object(args))
  }

  /// The name's characters that a shell and Claude Code's path detection
  /// read as they are, with the extension of the image's content.
  static func attachmentName(_ name: String, ext: String) -> String {
    let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
    let safe = String(stem.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
    return "\(safe.isEmpty ? "image" : safe).\(ext)"
  }

  /// Writes a file that did not exist. It adds -2, -3, and so on to the name
  /// when one does.
  private static func writeNew(_ data: Data, in folder: String, name: String) throws -> String {
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    for n in 1...100 {
      let path = "\(folder)/\(n == 1 ? stem : "\(stem)-\(n)").\(ext)"
      let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      if fd < 0 {
        if errno == EEXIST { continue }
        throw APIError("can't save \(name): \(UnixSocket.errnoText())")
      }
      defer { close(fd) }
      do {
        try UnixSocket.write(fd, data)
      } catch {
        try? FileManager.default.removeItem(atPath: path)
        throw APIError("can't save \(name): \(error)")
      }
      return path
    }
    throw APIError("can't save \(name): too many files with that name")
  }
}
