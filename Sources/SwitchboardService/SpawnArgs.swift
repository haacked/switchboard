import Foundation
import SwitchboardCore

/// The arguments of a `spawn` request, trimmed, with an empty value read as absent. The initializer checks
/// every rule that needs no session state. `spawn` still checks that `parent` names a session and that `wait`
/// is a state.
struct SpawnArgs {
  var repository: String
  var branch: String
  var prompt: String
  var followup: Bool
  var after: String?
  var base: String?
  var wait: String?
  var parent: String?
  var name: String?
  var model: String?
  var account: String?
  var group: String?
  var autoMode: Bool?
  var planMode: Bool?
  /// The host as the request names it, `local` included.
  var host: String?

  init(_ args: JSON) throws {
    func text(_ key: String) -> String? {
      args[key]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    guard let repository = text("repository") else { throw APIError("spawn needs a repository") }
    guard let branch = text("branch") else { throw APIError("spawn needs a branch") }
    guard let prompt = text("prompt") else { throw APIError("spawn needs a prompt") }
    let followup = args["followup"]?.bool == true
    let after = text("after")
    if after != nil, !followup { throw APIError("--after needs --followup, because a started session has no trigger") }
    if followup, text("base") != nil {
      throw APIError(
        "--base needs a started spawn, because a follow-up keeps no base. Pass --base to sb followup start")
    }
    let host = text("host")
    if followup, let host, host != SessionHost.local {
      throw APIError(
        "a follow-up starts on this Mac, so it can't run on \(host). Spawn it without --followup, or without --host")
    }
    let wait = text("wait")
    if wait != nil {
      if followup { throw APIError("wait needs a started spawn, because a follow-up has no state to reach") }
      guard text("parent") != nil else { throw APIError("wait needs a calling session to resume") }
    }
    self.repository = repository
    self.branch = branch
    self.prompt = prompt
    self.followup = followup
    self.after = after
    self.base = text("base")
    self.wait = wait
    self.parent = text("parent")
    self.name = text("name")
    self.model = text("model")
    self.account = text("account")
    self.group = text("group")
    self.autoMode = args["autoMode"]?.bool
    self.planMode = args["planMode"]?.bool
    self.host = host
  }
}
