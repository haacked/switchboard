import SwiftUI
import SwitchboardCore

/// Draws inline text that sbd or Claude wrote. `links` is false where the text
/// sits inside a button's label, because a link there gets no click.
struct InlineText: View {
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

  var body: some View { Text(text.attributed) }
}

extension MarkdownText {
  /// The text with its styles as presentation intents, and its links. `Text`
  /// draws presentation intents in the font around it.
  var attributed: AttributedString {
    var result = AttributedString()
    for run in runs {
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
      result += part
    }
    return result
  }
}
