import Foundation

/// config.json's `sessionNames` section: whether sbd asks a model to name a session that started without a name.
public struct SessionNameSettings: Codable, Equatable, Sendable {
  public var enabled = true
  public var model = "claude-haiku-5-5"
  /// How long one naming call may take before sbd ends it. It is at most `maxTimeout`.
  public var timeoutSeconds = 30.0

  static let maxTimeout = 120.0

  public init() {}

  public init(from decoder: Decoder) throws {
    self.init(parsing: try JSON(from: decoder))
  }

  /// Reads the section and never fails. It logs a bad value and keeps that
  /// value's default. So a typo can't make sbd ignore all of config.json.
  public init(parsing json: JSON?) {
    guard let json, json != .null else { return }
    guard let fields = json.object else {
      logLine("skipping sessionNames: its value must be an object")
      return
    }
    if let value = fields["enabled"] {
      if let enabled = value.bool {
        self.enabled = enabled
      } else {
        logLine("skipping sessionNames.enabled: its value must be true or false")
      }
    }
    if let value = fields["model"] {
      if let model = value.string, !model.isEmpty {
        self.model = model
      } else {
        logLine("skipping sessionNames.model: its value must be a model name")
      }
    }
    if let value = fields["timeoutSeconds"] {
      if let seconds = value.double, seconds > 0 {
        timeoutSeconds = min(seconds, Self.maxTimeout)
      } else {
        logLine("skipping sessionNames.timeoutSeconds: its value must be a number of seconds above 0")
      }
    }
  }
}

/// The one-shot call that names a session from its first prompt.
public enum SessionNamer {
  /// The most characters of the prompt that the call reads.
  public static let maxPrompt = 4000
  /// The most characters of a name the model gives. A suffix that makes the name unique may add more.
  public static let maxLength = 40
  /// 2 to 5 words of lowercase ASCII letters and digits, joined by single hyphens, that start with a letter.
  public static let pattern = "^[a-z][a-z0-9]*(-[a-z0-9]+){1,4}$"
  /// The first line of every input. The test stub routes the call by it.
  public static let marker = "<session-name-request>"
  static let tagPrefix = "session-name-"

  public static var system: String { Prompts.text(.sessionNamer) }

  public static let schema: JSON = [
    "type": "object",
    "properties": [
      "name": ["type": "string", "pattern": .string(pattern), "maxLength": .number(Double(maxLength))]
    ],
    "required": ["name"],
  ]

  /// The arguments of the `claude` command, after the program.
  public static func arguments(model: String) -> [String] {
    Headless.arguments(model: model, schema: schema, system: system)
  }

  /// The call's input. It holds the first `maxPrompt` characters of the
  /// prompt and each other part that is present, each between tags, and
  /// nothing else. A `<session-name-…` tag inside any part is escaped, so
  /// no part can close its tag.
  public static func input(prompt: String, repository: String?, branch: String?, issue: String?) -> String {
    func tagged(_ tag: String, _ text: String) -> String {
      "<\(tagPrefix)\(tag)>\(UntrustedText.untagged(text, tags: tagPrefix))</\(tagPrefix)\(tag)>"
    }
    var lines = [marker]
    if let repository { lines.append(tagged("repository", repository)) }
    if let branch { lines.append(tagged("branch", branch)) }
    if let issue { lines.append(tagged("issue", issue)) }
    lines.append(tagged("prompt", "\n\(prompt.prefix(maxPrompt))\n"))
    return lines.joined(separator: "\n")
  }

  /// The name in the output of `claude -p --output-format json`, which `validate` accepts.
  public static func parse(_ output: String) throws -> String {
    guard let name = try Headless.answer(output)["name"]?.string else {
      throw APIError("claude's answer holds no name")
    }
    return try validate(name)
  }

  /// The answer, trimmed and lowercased, when it matches `pattern` and has
  /// at most `maxLength` characters. It throws for anything else, and never
  /// repairs an answer.
  public static func validate(_ answer: String) throws -> String {
    let name = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard name.count <= maxLength, name.wholeMatch(of: try! Regex(pattern)) != nil else {
      throw APIError("claude's name is not 2 to 5 lowercase words joined by hyphens")
    }
    return name
  }

  /// The first of `name`, `name-2`, … `name-99` that `isFree` accepts, or nil when it accepts none.
  public static func unique(_ name: String, isFree: (String) -> Bool) -> String? {
    isFree(name) ? name : (2...99).lazy.map { "\(name)-\($0)" }.first(where: isFree)
  }
}
