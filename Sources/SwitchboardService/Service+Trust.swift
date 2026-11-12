import Foundation
import SwitchboardCore

/// Claude Code's workspace trust dialog. sbd trusts the folders it creates
/// for itself. It raises a card for the dialog in any other folder.
extension Service {
  /// Marks the session's folder trusted in the account that claude runs
  /// under, when sbd created the folder. Without it, claude stops at the
  /// trust dialog and reads no prompt.
  func trustOwnFolder(_ id: String) {
    guard let session = entries[id]?.session, let folder = ClaudeTrust.ownFolder(session, home: home) else { return }
    let account = claudeAccount(of: id)
    switch ClaudeTrust.trust(folder, account: account) {
    case .alreadyTrusted:
      break
    case .trusted(let key):
      record(id, "folder-trusted", ["folder": .string(folder), "key": .string(key), "account": .string(account)])
    case .noConfig:
      logLine("\(id): no trust written for \(folder), because \(account) has no .claude.json")
    case .refused(let reason):
      logLine("\(id): no trust written for \(folder): \(reason)")
    }
  }

  /// Records `trust_dialog` for each claude that shows the trust dialog,
  /// which opens a trust card. It checks a claude that runs with no hook
  /// since its launch, once per launch. It captures the screens off the
  /// state queue.
  func noteTrustDialogs() {
    let due: [(id: String, pane: String, launch: Int64?)] = queue.sync {
      entries.keys.sorted().compactMap { id in
        guard let f = entries[id]?.facts, case .running = claudeState(id), !f.hookSinceLaunch,
          f.trustLaunch != f.lastLaunch
        else { return nil }
        return (id, paneName(id, .claude), f.lastLaunch)
      }
    }
    guard !due.isEmpty else { return }
    let screens = due.map { ($0, try? host.screen($0.pane)) }
    queue.sync {
      for case (let s, let screen?) in screens {
        guard let f = entries[s.id]?.facts, f.lastLaunch == s.launch, f.trustLaunch != s.launch, !f.hookSinceLaunch,
          let folder = ClaudeScreen.dialog(screen).flatMap(ClaudeScreen.trustFolder)
        else { continue }
        var data: [String: JSON] = ["folder": .string(folder)]
        data["prompt"] = f.lastLaunchPrompt.map(JSON.string)
        data["launch"] = s.launch.map { .number(Double($0)) }
        record(s.id, "trust_dialog", .object(data))
      }
    }
  }

  /// Ends a trust card whose claude exited at the dialog. The launch's prompt,
  /// which claude never read, goes to the front of the queue, so the next
  /// start delivers it before later messages.
  func closeTrust(_ card: Card) {
    var data: [String: JSON] = ["card": .number(Double(card.id))]
    if let prompt = card.input["prompt"]?.string, !prompt.isEmpty {
      entries[card.session]?.pending.insert(QueuedMessage(text: prompt), at: 0)
      data["prompt"] = .string(prompt)
    }
    record(card.session, "trust_closed", .object(data))
  }
}
