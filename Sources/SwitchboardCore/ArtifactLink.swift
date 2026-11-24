import Foundation

/// The parser of claude.ai artifact links. A link is `https://claude.ai/artifact/<id>`
/// or `https://claude.ai/code/artifact/<id>`, and the id may hold only ASCII
/// letters, digits, `-`, and `_`. `URL.path` is percent-decoded, and the link
/// goes into the text of a chat's turns, so an id with `%0A` would add lines to
/// those turns.
public enum ArtifactLink {
  private static let idCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

  /// The link without its query or fragment, or nil for a link that is not a
  /// claude.ai artifact link.
  public static func normalized(_ text: String) -> String? {
    parts(of: text).map { "https://claude.ai/" + $0.joined(separator: "/") }
  }

  /// The artifact's id, or nil for a link that `normalized(_:)` refuses.
  public static func id(of text: String) -> String? {
    parts(of: text)?.last
  }

  /// The id of a `/code/artifact/<id>` link, or nil for any other link. Only that form's id is the
  /// `artifact_id` that a publish records.
  public static func artifactId(of text: String) -> String? {
    guard let parts = parts(of: text), parts.first == "code" else { return nil }
    return parts.last
  }

  private static func parts(of text: String) -> [String]? {
    guard let url = URL(string: text) else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard url.host?.lowercased() == "claude.ai", url.scheme?.lowercased() == "https", parts.count >= 2,
      [["artifact"], ["code", "artifact"]].contains(Array(parts.dropLast())),
      parts.last!.unicodeScalars.allSatisfy(idCharacters.contains)
    else { return nil }
    return parts
  }
}
