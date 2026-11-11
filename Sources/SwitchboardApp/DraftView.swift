import AppKit
import SwiftUI
import SwitchboardCore

enum DraftCopy {
  /// Writes the draft's Markdown source as plain text. Tests pass a named
  /// pasteboard so that they leave the user's clipboard alone.
  static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}

/// The drafts of an Inbox message, each in a quote with a copy button.
struct DraftsSection: View {
  let drafts: [TriageDraft]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: drafts.count == 1 ? "Draft" : "Drafts")
      ForEach(Array(drafts.enumerated()), id: \.offset) { DraftView(draft: $1) }
    }
  }
}

struct DraftView: View {
  /// A taller draft scrolls inside the quote, so the Action stays near the Summary.
  static let maxHeight: CGFloat = 240
  static let copiedSeconds = 1.5

  let draft: TriageDraft
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label = draft.label { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
      HStack(spacing: 0) {
        QuoteBar()
        ScrollView {
          MarkdownView(text: draft.text)
            .padding(.leading, 10)
            .padding(.trailing, 36)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
      }
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(alignment: .topTrailing) { copyButton.padding(6) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(draft.label.map { "Draft: \($0)" } ?? "Draft")
  }

  private var copyButton: some View {
    Button {
      DraftCopy.copy(draft.text)
      copied = true
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedSeconds) { copied = false }
    } label: {
      if copied {
        Label("Copied", systemImage: "checkmark").labelStyle(.titleAndIcon)
      } else {
        Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Capsule().fill(.background.opacity(0.85)))
    .help("Copy the draft's text")
    .accessibilityLabel(copied ? "Copied" : "Copy draft")
  }
}
