import AppKit
import Combine
import SwitchboardCore

/// The message field's drafts, one per target, kept while the app runs and saved to `folder` so that they
/// survive a relaunch. `folder` holds `drafts.json` and one file per image, named by the image's id. A store
/// without a folder keeps its drafts in memory only.
@MainActor
final class MessageDrafts {
  private struct Saved: Codable {
    struct Image: Codable {
      var id: UUID
      var name: String
    }

    var text: String
    var images: [Image]
  }

  let folder: String?
  private var drafts: [String: MessageField.Draft] = [:]
  private var changes: [String: AnyCancellable] = [:]
  private var pendingSave: DispatchWorkItem?
  /// Writes run here in order, because an image file can be 20 MB.
  private let io = DispatchQueue(label: "switchboard.drafts")

  init(folder: String?) {
    self.folder = folder
    load()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveNow() }
    }
  }

  /// A group chat's draft follows the group, so a new chat session for the group keeps it.
  static func key(for session: SessionSummary) -> String {
    session.chat.map { "group:\($0)" } ?? session.id
  }

  func draft(for key: String) -> MessageField.Draft {
    if let draft = drafts[key] { return draft }
    let draft = MessageField.Draft()
    add(draft, for: key)
    return draft
  }

  /// Drops the drafts of targets that no longer exist.
  func prune(keeping keys: Set<String>) {
    let gone = drafts.keys.filter { !keys.contains($0) }
    guard !gone.isEmpty else { return }
    for key in gone {
      drafts[key] = nil
      changes[key] = nil
    }
    scheduleSave()
  }

  /// Saves the drafts and returns once the files are written.
  func saveNow() {
    save()
    io.sync {}
  }

  /// Writes the drafts that hold something, and deletes the image files that none of them names.
  private func save() {
    pendingSave?.cancel()
    pendingSave = nil
    guard let folder else { return }
    let kept = drafts.filter { !$0.value.isEmpty }
    let saved = kept.mapValues { draft in
      Saved(text: draft.text, images: draft.images.map { Saved.Image(id: $0.id, name: $0.name) })
    }
    let images = Dictionary(
      kept.values.flatMap(\.images).map { ($0.id.uuidString, $0.data) }, uniquingKeysWith: { first, _ in first })
    io.async { Self.write(saved, images: images, to: folder) }
  }

  private nonisolated static func write(_ saved: [String: Saved], images: [String: Data], to folder: String) {
    let files = FileManager.default
    func url(_ name: String) -> URL { URL(fileURLWithPath: "\(folder)/\(name)") }
    do {
      try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
      for (name, data) in images where !files.fileExists(atPath: url(name).path) {
        try data.write(to: url(name), options: .atomic)
      }
      try JSONCoding.encoder.encode(saved).write(to: url(index), options: .atomic)
      for name in try files.contentsOfDirectory(atPath: folder) where name != index && images[name] == nil {
        try? files.removeItem(at: url(name))
      }
    } catch {
      NSLog("Switchboard could not save the message drafts in \(folder): \(error)")
    }
  }

  private nonisolated static let index = "drafts.json"
  private static let saveDelay: TimeInterval = 0.5

  private func path(_ name: String) -> String { "\(folder ?? "")/\(name)" }

  /// Saves follow the text and the images only. The Esc hint and the error are not saved.
  private func add(_ draft: MessageField.Draft, for key: String) {
    drafts[key] = draft
    changes[key] = draft.$text.dropFirst().map { _ in }.merge(with: draft.$images.dropFirst().map { _ in })
      .sink { [weak self] in self?.scheduleSave() }
  }

  private func scheduleSave() {
    guard folder != nil else { return }
    pendingSave?.cancel()
    let save = DispatchWorkItem { [weak self] in self?.save() }
    pendingSave = save
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
  }

  private func load() {
    guard folder != nil, let data = FileManager.default.contents(atPath: path(Self.index)),
      let saved = try? JSONCoding.decoder.decode([String: Saved].self, from: data)
    else { return }
    for (key, entry) in saved {
      let draft = MessageField.Draft()
      draft.text = entry.text
      for image in entry.images {
        guard let bytes = FileManager.default.contents(atPath: path(image.id.uuidString)) else { continue }
        draft.append(id: image.id, name: image.name, data: bytes)
      }
      add(draft, for: key)
    }
  }
}
