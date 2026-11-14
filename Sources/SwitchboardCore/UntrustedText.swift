import Foundation

/// Text from outside, such as a PR description or an issue body, that a prompt sets between tags and marks as data.
enum UntrustedText {
  /// The text with the `<` of each tag whose name starts with `prefix`, opening or closing, in any case and spacing,
  /// written as `&lt;`. The text then can't open or close the tags that a prompt puts around it.
  static func untagged(_ text: String, tags prefix: String) -> String {
    let pattern = #"<(?=\s*/?\s*"# + NSRegularExpression.escapedPattern(for: prefix) + ")"
    let tag = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    return tag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "&lt;")
  }
}
