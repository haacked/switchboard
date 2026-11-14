import AppKit
import Combine
import ImageIO
import SwitchboardCore

extension MessageField {
  /// What the field holds. MessageDrafts keeps one per target, so it outlives the view.
  final class Draft: ObservableObject {
    struct Image: Identifiable {
      var id = UUID()
      let name: String
      let data: Data
      let thumbnail: NSImage?
    }

    @Published var text = ""
    @Published var images: [Image] = []
    /// Why the last drop or paste left files out.
    @Published var error: String?
    /// The time of the first Esc. A second Esc within `escapeWindow` of it clears the draft.
    @Published private var armedAt: Date?
    var escapeHint: Bool { armedAt != nil }

    var isEmpty: Bool { trimmed.isEmpty && images.isEmpty }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Sends the trimmed text and the images, and empties the field once sbd accepts them, unless the user
    /// changed it meanwhile.
    @MainActor func submit(_ session: String, to model: BoardModel) {
      guard !isEmpty else { return }
      let sent = trimmed
      let ids = images.map(\.id)
      model.send(session, sent, images: images.map { ($0.name, $0.data) }) { [weak self] in
        self?.clear(ifStill: sent, images: ids)
      }
    }

    /// Empties the text unless the user changed it after `sent` was sent, and removes the sent images.
    func clear(ifStill sent: String, images sentImages: [Image.ID] = []) {
      if trimmed == sent { text = "" }
      images.removeAll { sentImages.contains($0.id) }
      error = nil
    }

    /// Adds each image file in order, and sets `error` for each file that is not one.
    /// Returns the paths it left out.
    @discardableResult
    func add(paths: [String]) -> [String] {
      attach(
        paths.map { path in
          ((path as NSString).lastPathComponent, { try Attachments.read(path: path, remaining: $0) })
        }
      ).map { paths[$0] }
    }

    /// Adds each file in order while the message stays within `Attachments.checkMessage`. It leaves out a file
    /// that fails to read or would pass a limit, and `error` names that file. The files after it still attach.
    /// A file past the count limit is not read. A file larger than the room left under the total limit is not read.
    /// Returns the indexes of the files it left out.
    @discardableResult
    private func attach(_ files: [(name: String, read: (_ remaining: Int) throws -> Data)]) -> [Int] {
      var refused: [String] = []
      var overLimit: [(reason: String, names: [String])] = []
      var leftOut: [Int] = []
      func leaveOut(_ name: String, _ error: any Error) {
        let reason = "\(error)"
        if let i = overLimit.firstIndex(where: { $0.reason == reason }) {
          overLimit[i].names.append(name)
        } else {
          overLimit.append((reason, [name]))
        }
      }
      var total = images.reduce(0) { $0 + $1.data.count }
      for (index, file) in files.enumerated() {
        leftOut.append(index)
        do {
          try Attachments.checkMessage(count: images.count + 1, total: total)
        } catch {
          leaveOut(file.name, error)
          continue
        }
        let data: Data
        do {
          data = try file.read(Attachments.totalLimit - total)
        } catch let error as Attachments.OverTotalLimit {
          leaveOut(file.name, error)
          continue
        } catch {
          refused.append("\(error)")
          continue
        }
        do {
          try Attachments.checkMessage(count: images.count + 1, total: total + data.count)
        } catch {
          leaveOut(file.name, error)
          continue
        }
        leftOut.removeLast()
        append(name: file.name, data: data)
        total += data.count
      }
      for (reason, names) in overLimit {
        refused.append("\(names.joined(separator: ", ")) \(names.count == 1 ? "isn't" : "aren't") attached: \(reason)")
      }
      error = refused.isEmpty ? nil : refused.joined(separator: " ")
      return leftOut
    }

    /// Adds the pasteboard's images and returns true, or returns false and leaves the paste to the
    /// text field. It takes file URLs when every one names an image file, and the PNG or TIFF data of
    /// each item when no item has text.
    func paste(from pasteboard: NSPasteboard) -> Bool {
      let urls = pasteboard.fileURLs
      if !urls.isEmpty {
        guard urls.allSatisfy({ Attachments.extensions.contains($0.pathExtension.lowercased()) }) else {
          return false
        }
        add(paths: urls.map(\.path))
        return true
      }
      let items = pasteboard.pasteboardItems ?? []
      guard !items.contains(where: { $0.types.contains(.string) }) else { return false }
      let images = items.filter { $0.types.contains(.png) || $0.types.contains(.tiff) }
      guard !images.isEmpty else { return false }
      attach(images.map { item in (Self.pastedName, { _ in try Self.png(item) }) })
      return true
    }

    /// The item's PNG data, or its TIFF data converted to PNG.
    private static func png(_ item: NSPasteboardItem) throws -> Data {
      let png =
        item.data(forType: .png)
        ?? item.data(forType: .tiff).flatMap {
          NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        } ?? Data()
      _ = try Attachments.validate(name: pastedName, data: png)
      return png
    }

    func remove(_ id: Image.ID) {
      images.removeAll { $0.id == id }
    }

    static let escapeWindow: TimeInterval = 1

    /// Handles an Esc and returns true when it cleared the draft. A first Esc on a draft with something in it
    /// only sets `escapeHint`. The field then handles the key as it would without a draft.
    func escape(at now: Date) -> Bool {
      guard !isEmpty else {
        disarmEscape()
        return false
      }
      if let armedAt, now.timeIntervalSince(armedAt) <= Self.escapeWindow {
        text = ""
        images = []
        error = nil
        disarmEscape()
        return true
      }
      armedAt = now
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.escapeWindow) { [weak self] in
        if self?.armedAt == now { self?.disarmEscape() }
      }
      return false
    }

    /// Ends the window in which a second Esc clears the draft.
    func disarmEscape() {
      if armedAt != nil { armedAt = nil }
    }

    static let pastedName = "Pasted image.png"

    func append(id: UUID = UUID(), name: String, data: Data) {
      images.append(Image(id: id, name: name, data: data, thumbnail: Self.thumbnail(data)))
    }

    /// A small decoded copy, so that a chip does not keep the full image's bitmap.
    private static func thumbnail(_ data: Data) -> NSImage? {
      let options =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 56,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      else { return nil }
      return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
  }
}
