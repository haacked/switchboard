import Foundation
import SwitchboardCore

/// The Manager session. `plans/triage.md` in the notes repo describes it.
extension Service {
  /// The `manager` request: creates the Manager the first time, and opens it
  /// (resumes a stopped claude) after that.
  func managerRequest() -> Response {
    do {
      try ensureManagerFolder()
      awaitMCPServers()
      if let id = queue.sync(execute: managerID) { return handle(Request(op: "open", args: ["session": .string(id)])) }
      return try queue.sync {
        if let id = managerID() { return .success(try JSON(encoding: summary(id))) }
        let folder = home.managerFolder
        let created = try create(NewSession(path: folder, name: Manager.name), (folder, nil))
        try update(created.id) { $0.manager = true }
        return .success(try JSON(encoding: summary(created.id)))
      }
    } catch {
      return .failure("\(error)")
    }
  }

  func managerID() -> String? {
    entries.values.first { $0.session.manager == true }?.session.id
  }

  /// Makes the Manager's folder a git repo with the current CLAUDE.md.
  func ensureManagerFolder() throws {
    try FileManager.default.createDirectory(atPath: home.managerFolder, withIntermediateDirectories: true)
    try refreshManagerGuide()
  }

  /// Rewrites CLAUDE.md when it differs. It does nothing until `sb manager`
  /// has made the folder, so a user who never runs `sb manager` gets none.
  func refreshManagerGuide() throws {
    let folder = home.managerFolder
    guard isDirectory(folder) else { return }
    if !isDirectory("\(folder)/.git") { _ = try gitOutput(folder, ["init", "-q"]) }
    let path = "\(folder)/CLAUDE.md"
    if (try? String(contentsOfFile: path, encoding: .utf8)) != Manager.guide {
      try Manager.guide.write(toFile: path, atomically: true, encoding: .utf8)
    }
  }
}
