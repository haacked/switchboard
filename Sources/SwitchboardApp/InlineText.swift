import SwiftUI
import SwitchboardCore

/// Draws inline text that sbd or Claude wrote, with each session id that
/// resolves drawn as the session's name. `links` is false where the text sits
/// inside a button's label, because a link there gets no click.
struct InlineText: View {
  @Environment(\.sessionNames) private var names
  let text: MarkdownText
  let links: Bool

  init(_ text: MarkdownText, links: Bool = true) {
    self.text = text
    self.links = links
  }

  /// A plain string, drawn as one unstyled run. No Markdown in it is parsed.
  init(plain: String, links: Bool = true) {
    self.init(MarkdownText(stringLiteral: plain), links: links)
  }

  var body: some View {
    let (attributed, help) = Self.attributed(text, names: names, links: links)
    if let help { Text(attributed).help(help) } else { Text(attributed) }
  }

  /// The text with each matched id swapped for the session's name. With
  /// `links`, a live session's name links to the session, and `help` lists
  /// each swapped session as `name: id`, once each, in the order the text
  /// names them. A removed session's name never links.
  static func attributed(_ text: MarkdownText, names: SessionNames, links: Bool) -> (AttributedString, help: String?) {
    var result = AttributedString()
    var lines: [String] = []
    var listed: Set<String> = []
    for piece in names.pieces(text) {
      var part = MarkdownText.attributed(piece.run)
      if let match = piece.match, links {
        if !match.removed { part.link = SessionLink.url(for: match.id) }
        if listed.insert(match.id).inserted {
          lines.append("\(match.name): \(match.id)" + (match.removed ? ", removed" : ""))
        }
      }
      result += part
    }
    return (result, lines.isEmpty ? nil : lines.joined(separator: "\n"))
  }
}

extension MarkdownText {
  /// The text with its styles as presentation intents, and its links. `Text`
  /// draws presentation intents in the font around it.
  var attributed: AttributedString { runs.reduce(into: AttributedString()) { $0 += Self.attributed($1) } }

  static func attributed(_ run: Run) -> AttributedString {
    var part = AttributedString(run.text.isEmpty ? run.image ?? "" : run.text)
    var intent: InlinePresentationIntent = []
    if run.style.contains(.emphasis) { intent.insert(.emphasized) }
    if run.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
    if run.style.contains(.code) { intent.insert(.code) }
    if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
    if !intent.isEmpty { part.inlinePresentationIntent = intent }
    if run.style.contains(.footnote) {
      part.baselineOffset = 6
      part.font = .caption2
    }
    if let link = (run.link ?? run.image).flatMap(URL.init(string:)) { part.link = link }
    return part
  }
}

/// The URL of a link to a session. Only the app's own views see the scheme,
/// because it is not registered with Launch Services.
enum SessionLink {
  private static let prefix = "switchboard-session:"

  /// `id` is a session id, so the string always parses as a URL.
  static func url(for id: String) -> URL { URL(string: prefix + id)! }

  /// The session id of a link that `url(for:)` made, else nil.
  static func id(from url: URL) -> String? {
    let string = url.absoluteString
    guard string.hasPrefix(prefix) else { return nil }
    let id = String(string.dropFirst(prefix.count))
    return SessionNames.isSessionID(id) ? id : nil
  }
}

private struct SessionNamesKey: EnvironmentKey {
  static let defaultValue = SessionNames(live: [:], removed: [:])
}

extension EnvironmentValues {
  /// The directory that `InlineText` resolves session ids with. A host that
  /// never sets it draws the ids as written.
  var sessionNames: SessionNames {
    get { self[SessionNamesKey.self] }
    set { self[SessionNamesKey.self] = newValue }
  }
}

extension View {
  /// Gives `InlineText` the model's session names, and opens a session link
  /// through `reveal`. Every other URL goes to the system.
  func sessionLinks(_ model: BoardModel) -> some View {
    environment(\.sessionNames, model.sessionNames)
      .environment(\.openURL, OpenURLAction { model.openSessionLink($0) ? .handled : .systemAction })
  }
}
