/// The words for a PermissionRequest's `permission_suggestions`, which an
/// always-allow sends back to Claude Code unchanged.
public enum AlwaysAllow {
  /// The words for each destination that a suggestion can save to.
  static let destinations: [String: String] = [
    "session": "for this session",
    "localSettings": "in this project's local settings, .claude/settings.local.json",
    "projectSettings": "in this project's shared settings, .claude/settings.json",
    "userSettings": "in your user settings, ~/.claude/settings.json",
  ]

  /// What applying every suggestion does, one sentence per suggestion, or nil
  /// when any suggestion has a shape this can't describe. sbd sends the
  /// suggestions verbatim, so a key or a value outside the known shapes makes
  /// the whole list undescribable.
  public static func describe(_ suggestions: JSON?) -> String? {
    guard let entries = suggestions?.array, !entries.isEmpty else { return nil }
    let sentences = entries.compactMap(sentence)
    guard sentences.count == entries.count else { return nil }
    return sentences.joined(separator: ". ")
  }

  private static func sentence(_ entry: JSON) -> String? {
    guard let fields = entry.object, let type = fields["type"]?.string,
      let place = fields["destination"]?.string.flatMap({ destinations[$0] })
    else { return nil }
    let keys = Set(fields.keys)
    switch type {
    case "addDirectories":
      guard keys == ["type", "destination", "directories"], let directories = texts(fields["directories"]) else {
        return nil
      }
      return "Always allow access to \(englishList(directories)) \(place)"
    case "addRules":
      guard keys == ["type", "destination", "rules", "behavior"], fields["behavior"] == "allow",
        let list = fields["rules"]?.array, !list.isEmpty
      else { return nil }
      let rules = list.compactMap(rule)
      guard rules.count == list.count else { return nil }
      return "Always allow \(englishList(rules)) \(place)"
    case "setMode":
      guard keys == ["type", "destination", "mode"], let mode = text(fields["mode"]), safeModes.contains(mode) else {
        return nil
      }
      return "Set the permission mode to \(mode) \(place)"
    default:
      return nil
    }
  }

  /// The modes an always-allow may switch to. Auto mode has its own allow,
  /// which also records the mode. A mode that skips every prompt needs more
  /// than one click.
  static let safeModes: Set<String> = ["acceptEdits"]

  /// The rule as Claude Code's settings write it, such as `Bash(npm test:*)`.
  private static func rule(_ rule: JSON) -> String? {
    guard let fields = rule.object, Set(fields.keys).isSubset(of: ["toolName", "ruleContent"]),
      let tool = text(fields["toolName"])
    else { return nil }
    guard let content = fields["ruleContent"] else { return tool }
    return text(content).map { "\(tool)(\($0))" }
  }

  private static func texts(_ value: JSON?) -> [String]? {
    guard let list = value?.array, !list.isEmpty else { return nil }
    let strings = list.compactMap(text)
    return strings.count == list.count ? strings : nil
  }

  /// The categories of characters that break a sentence apart, reorder it, or
  /// hide in it, as a newline, a right-to-left override, or a zero-width space do.
  private static let misleading: Set<Unicode.GeneralCategory> = [
    .control, .format, .lineSeparator, .paragraphSeparator,
  ]

  /// A string that reads the same in every place the description shows. An
  /// empty or blank string names nothing.
  private static func text(_ value: JSON?) -> String? {
    guard let string = value?.string, !string.trimmingCharacters(in: .whitespaces).isEmpty,
      !string.unicodeScalars.contains(where: { misleading.contains($0.properties.generalCategory) })
    else { return nil }
    return string
  }
}
