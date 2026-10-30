import SwiftUI
import SwitchboardCore

/// Draws Markdown: `MarkdownBlock` finds the blocks, and SwiftUI's inline
/// Markdown draws the text of each.
struct MarkdownView: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
        view(block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func view(_ block: MarkdownBlock) -> some View {
    switch block {
    case .heading(let level, let text):
      inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).padding(.top, 4)
    case .paragraph(let text):
      inline(text)
    case .list(let number, let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number.map { "\($0 + i)." } ?? "•").foregroundStyle(.secondary).monospacedDigit()
            inline(item)
          }
        }
      }
      .padding(.leading, 6)
    case .code(_, let text):
      ScrollView(.horizontal) {
        Text(text).font(.callout.monospaced()).padding(8).fixedSize(horizontal: true, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    case .quote(let text):
      HStack(spacing: 8) {
        Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
        inline(text).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .rule:
      Divider()
    }
  }

  private func inline(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
  }
}
