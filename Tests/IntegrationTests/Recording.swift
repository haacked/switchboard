import Foundation
import SwitchboardCore

/// The hook payloads that the real claude sent for one step of a session,
/// such as a turn or a resume. Fixtures/claude/<step>.jsonl holds one payload
/// per line. Values that change from run to run are placeholders such as
/// {{session_id}}, so a rerun on the same Claude Code version writes the same
/// text, and the stub fills them in for its own session.
enum Recording {
  static let folder = Instance.root.appendingPathComponent("Tests/IntegrationTests/Fixtures/claude").path

  /// The values that the test chose for the run.
  struct Context {
    /// The work folder, as sbd names it and as claude names it.
    var cwd: [String]
    var home: String
    var nonce: String
    var prompts: [String] = []
    var commands: [String] = []
  }

  /// Keys whose values change from run to run, and the name of each value's
  /// placeholder. Every place a value appears gets its placeholder.
  static let keyPlaceholders = [
    "prompt_id": "prompt_id", "tool_use_id": "tool_use_id", "agent_id": "agent_id", "backgroundTaskId": "task_id",
    "description": "description",
  ]
  /// Most steps have one session and one description, so the first of each
  /// has no number.
  static let unnumbered: Set = ["session_id", "description"]

  static func normalize(_ payloads: [JSON], _ context: Context) -> [JSON] {
    var substitutions: [(String, String)] = []
    var counts: [String: Int] = [:]
    func add(_ value: String, _ name: String) {
      guard !value.isEmpty, !substitutions.contains(where: { $0.0 == value }) else { return }
      counts[name, default: 0] += 1
      let n = counts[name]!
      substitutions.append((value, n == 1 && unnumbered.contains(name) ? "{{\(name)}}" : "{{\(name)_\(n)}}"))
    }
    func collect(_ value: JSON) {
      switch value {
      case .object(let o):
        for (key, v) in o.sorted(by: { $0.key < $1.key }) {
          if let name = keyPlaceholders[key], let s = v.string { add(s, name) }
          if key == "background_tasks", let tasks = v.array {
            for case let id? in tasks.map({ $0["id"]?.string }) { add(id, "task_id") }
          }
          collect(v)
        }
      case .array(let a):
        a.forEach(collect)
      default:
        break
      }
    }
    // Session ids come first, so the first session is {{session_id}} in each step.
    for p in payloads { if let s = p["session_id"]?.string { add(s, "session_id") } }
    payloads.forEach(collect)
    if let paths = claudePaths(payloads) {
      substitutions += [
        (paths.configDir, "{{config_dir}}"), (paths.encodedCwd, "{{encoded_cwd}}"), (paths.tmp, "{{claude_tmp}}"),
      ]
    }
    substitutions += context.cwd.map { ($0, "{{cwd}}") }
    substitutions += [(context.nonce, "{{nonce}}"), (context.home, "{{home}}")]
    // A longer value can hold a shorter one, as the config folder holds the home folder.
    let ordered = substitutions.filter { !$0.0.isEmpty }.sorted { $0.0.count > $1.0.count }

    // A prompt at the top of a payload is the session's own. A nested one is
    // the prompt that the model wrote for a subagent.
    func rewrite(_ value: JSON, key: String?, nested: Bool) -> JSON {
      switch value {
      case .string(let s):
        switch key {
        case "last_assistant_message": return "{{reply}}"
        case "prompt" where context.prompts.contains(s): return "{{prompt}}"
        case "prompt" where nested: return "{{agent_prompt}}"
        case "command" where context.commands.contains(s): return "{{command}}"
        default:
          // A subagent's result reports its token count and duration in
          // elements such as <tool_uses>3</tool_uses>. The model writes the
          // text in its <result> element.
          let text = ordered.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            .replacingOccurrences(of: ">[0-9]+<", with: ">0<", options: .regularExpression)
          return .string(
            text.replacingOccurrences(
              of: "<result>[\\s\\S]*?</result>", with: "<result>{{result}}</result>", options: .regularExpression))
        }
      case .number:
        // The numbers in hook payloads are durations, token counts, and costs.
        return 0
      case .object(let o):
        return .object(
          Dictionary(uniqueKeysWithValues: o.map { ($0.key, rewrite($0.value, key: $0.key, nested: key != nil)) }))
      case .array(let a):
        return .array(a.map { rewrite($0, key: key, nested: nested) })
      default:
        return value
      }
    }
    return payloads.map { rewrite($0, key: nil, nested: false) }
  }

  /// The folders that claude derives from the work folder, read from a
  /// payload's transcript_path (<config>/projects/<encoded cwd>/<id>.jsonl)
  /// and scratchpad_dir (<tmp>/<encoded cwd>/<id>/scratchpad).
  static func claudePaths(_ payloads: [JSON]) -> (configDir: String, encodedCwd: String, tmp: String)? {
    guard let p = payloads.first(where: { $0["transcript_path"] != nil && $0["scratchpad_dir"] != nil }),
      let transcript = p["transcript_path"]?.string, let scratchpad = p["scratchpad_dir"]?.string
    else { return nil }
    let project = (transcript as NSString).deletingLastPathComponent
    let encoded = (project as NSString).lastPathComponent
    let config = ((project as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    guard let range = scratchpad.range(of: "/\(encoded)/") else { return nil }
    return (config, encoded, String(scratchpad[..<range.lowerBound]))
  }

  static func write(_ payloads: [JSON], to path: String) throws {
    try payloads.map { $0.text + "\n" }.joined().write(toFile: path, atomically: true, encoding: .utf8)
  }

  static func read(_ path: String) throws -> [JSON] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
      guard let payload = JSON.parse(String($0)) else { throw TestError(description: "bad line in \(path): \($0)") }
      return payload
    }
  }
}

extension Instance {
  /// The session's hook events after the event id `after`, oldest first.
  func hooks(_ id: String, after: Int64 = 0) throws -> [Event] {
    try client.call(
      "events", ["session": .string(id), "since": .number(Double(after)), "limit": 10_000], as: [Event].self
    ).filter { $0.data["hook_event_name"] != nil }
  }

  /// The hook payloads of one step: the session's hook events after the event
  /// id `after`, through the event id `through`.
  func stepPayloads(_ id: String, after: Int64, through: Int64 = .max) throws -> [JSON] {
    try hooks(id, after: after).filter { $0.id <= through }.map(\.data)
  }

  /// The session's newest event.
  func lastEvent(_ id: String) throws -> Event? {
    try client.call("events", ["session": .string(id), "limit": 1], as: [Event].self).last
  }
}
