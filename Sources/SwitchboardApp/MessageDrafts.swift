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
  /// True while a draft may be under a group's key. `load` finds such a key in a file that an older app saved.
  private var hasGroupDrafts = false
  /// Writes run here in order, because an image file can be 20 MB.
  private let io = DispatchQueue(label: "switchboard.drafts")
  private let saveDelay: TimeInterval

  /// `saveDelay` is how long after the last change a save waits.
  init(folder: String?, saveDelay: TimeInterval = 0.5) {
    self.folder = folder
    self.saveDelay = saveDelay
    load()
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.saveNow() }
    }
  }

  /// Each session keeps its own draft, so each conversation of a group chat has its own.
  static func key(for session: SessionSummary) -> String { session.id }

  /// The prefix of the key under which an app from before several conversations per group kept a group chat's
  /// draft, with the group's id after it.
  private static let groupKeyPrefix = "group:"

  /// The key of the unsent Other answer to one decision of a session's list. The list's ref is part of the key,
  /// so a later list's decision with the same number starts empty.
  static func otherAnswerKey(session: String, ref: String, decision: Int) -> String {
    "decision:\(session)/\(ref)/\(decision)/other"
  }

  /// The key of the unsent question in one decision's thread, keyed like `otherAnswerKey`.
  static func askKey(session: String, ref: String, decision: Int) -> String {
    "decision:\(session)/\(ref)/\(decision)/ask"
  }

  /// The draft keys of every decision that the sessions show.
  static func decisionKeys(_ sessions: [SessionSummary]) -> Set<String> {
    Set(
      sessions.flatMap { s in
        s.shownDecisions.map { list in
          list.decisions.flatMap { d in
            [
              otherAnswerKey(session: s.id, ref: list.ref, decision: d.number),
              askKey(session: s.id, ref: list.ref, decision: d.number),
            ]
          }
        } ?? []
      })
  }

  /// The key of the unsent answer to the Operator's question on a session. It is apart from the session's own draft,
  /// so text typed for the Operator never sends to the session's claude, and the reverse. The key names no report,
  /// so a newer question on the same session keeps the text.
  static func operatorAnswerKey(session: String) -> String { "operator-answer:\(session)" }

  /// The Operator answer keys of every session whose item is an Operator question.
  static func operatorAnswerKeys(_ sessions: [SessionSummary]) -> Set<String> {
    Set(
      sessions.filter { MessageField.Draft.answersOperator(ref: $0.triage?.ref) }.map {
        operatorAnswerKey(session: $0.id)
      })
  }

  /// The key of the user's edit of a draft reply. A new card is a new ref, so its draft of the same number starts
  /// from the session's text.
  static func replyKey(session: String, ref: String, number: Int) -> String {
    "reply:\(session)/\(ref)/\(number)"
  }

  /// The reply keys of every draft that shows an editable reply. A posted draft has nothing left to post.
  static func replyKeys(_ sessions: [SessionSummary]) -> Set<String> {
    Set(
      sessions.flatMap { s in
        guard let item = s.triage else { return [String]() }
        return item.drafts.filter { draft in
          switch draft.post {
          case .copyOnly, .posted: false
          default: DraftsSection.usesReplyView(draft, in: item)
          }
        }.map { replyKey(session: s.id, ref: item.ref, number: $0.number) }
      })
  }

  func draft(for key: String) -> MessageField.Draft {
    if let draft = drafts[key] { return draft }
    let draft = MessageField.Draft()
    add(draft, for: key)
    return draft
  }

  /// Moves each draft kept under a group's key to the session that `chat` returns for the group, which is the
  /// group's most recent conversation. A session that already holds a draft gets the group's text after its own,
  /// and the group's images after its own. The group's key then goes away. It does nothing once no group's key
  /// remains.
  func moveGroupDrafts(to chat: (String) -> String?) {
    guard hasGroupDrafts else { return }
    var moved = false
    for (key, legacy) in drafts where key.hasPrefix(Self.groupKeyPrefix) {
      guard let id = chat(String(key.dropFirst(Self.groupKeyPrefix.count))) else { continue }
      drafts[key] = nil
      changes[key] = nil
      if let target = drafts[id], !target.isEmpty {
        target.text = [target.text, legacy.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        target.images += legacy.images
      } else {
        add(legacy, for: id)
      }
      moved = true
    }
    hasGroupDrafts = drafts.keys.contains { $0.hasPrefix(Self.groupKeyPrefix) }
    if moved { scheduleSave() }
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
    func url(_ name: String) -> URL { Self.url(name, in: folder) }
    do {
      // The drafts hold text that the user has not sent, so only the user can read them.
      try files.createDirectory(
        atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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

  private nonisolated static func url(_ name: String, in folder: String) -> URL {
    URL(fileURLWithPath: "\(folder)/\(name)")
  }

  /// Only a change to the text or the images schedules a save. The Esc hint and the error are not saved.
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
    DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: save)
  }

  private func load() {
    guard let folder, let data = FileManager.default.contents(atPath: Self.url(Self.index, in: folder).path),
      let saved = try? JSONCoding.decoder.decode([String: Saved].self, from: data)
    else { return }
    for (key, entry) in saved {
      let draft = MessageField.Draft()
      draft.text = entry.text
      for image in entry.images {
        guard let bytes = FileManager.default.contents(atPath: Self.url(image.id.uuidString, in: folder).path)
        else { continue }
        draft.append(id: image.id, name: image.name, data: bytes)
      }
      add(draft, for: key)
    }
    hasGroupDrafts = saved.keys.contains { $0.hasPrefix(Self.groupKeyPrefix) }
  }
}
