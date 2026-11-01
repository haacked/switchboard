import SwiftUI
import SwitchboardCore

/// Draws Markdown: `MarkdownBlock` finds the blocks, and SwiftUI's inline
/// Markdown draws the text of each.
struct MarkdownView: View {
  let text: String

  var body: some View {
    MarkdownBlocksView(blocks: MarkdownBlock.parse(text))
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }
}

/// The blocks of a document, or of a list item or quote inside one.
private struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(block)
      }
    }
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
            marker(number.map { "\($0 + i)." } ?? "•", checked: item.checked)
            MarkdownBlocksView(blocks: item.blocks)
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
    case .quote(let blocks):
      HStack(spacing: 8) {
        Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
        MarkdownBlocksView(blocks: blocks).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let header, let alignments, let rows):
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
              tableCell(cell, alignments[c], header: true).gridColumnAlignment(alignments[c].horizontal)
            }
          }
          Divider()
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { c, cell in tableCell(cell, alignments[c], header: false)
              }
            }
          }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
      }
      .scrollIndicators(.visible)
    case .rule:
      Divider()
    }
  }

  @ViewBuilder
  private func marker(_ text: String, checked: Bool?) -> some View {
    if let checked {
      Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
    } else {
      Text(text).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  private func tableCell(_ text: String, _ align: MarkdownBlock.Alignment, header: Bool) -> some View {
    CappedWidthLayout(limit: 320) {
      (header ? inline(text).bold() : inline(text))
        .multilineTextAlignment(align.text)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: align.horizontal, vertical: .top))
    }
  }

  private static let inlineOptions = AttributedString.MarkdownParsingOptions(
    interpretedSyntax: .inlineOnlyPreservingWhitespace)

  private func inline(_ text: String) -> Text {
    Text((try? AttributedString(markdown: text, options: Self.inlineOptions)) ?? AttributedString(text))
  }
}

/// Sizes its one child to the child's natural width, or to `limit` when the
/// child is wider, and measures the height at that width. A horizontal
/// ScrollView proposes no width, so a plain `frame(maxWidth:)` would measure a
/// wrapped cell's height as one line.
private struct CappedWidthLayout: Layout {
  let limit: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let natural = child.sizeThatFits(.unspecified).width
    return child.sizeThatFits(ProposedViewSize(width: min(natural, limit), height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

extension MarkdownBlock.Alignment {
  fileprivate var horizontal: HorizontalAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  fileprivate var text: TextAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}
