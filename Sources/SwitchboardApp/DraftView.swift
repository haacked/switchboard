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
  let session: SessionSummary
  let item: TriageItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: item.drafts.count == 1 ? "Draft" : "Drafts")
      ForEach(Array(item.drafts.enumerated()), id: \.offset) { DraftView(draft: $1) }
    }
  }
}

struct DraftView: View {
  let draft: InboxDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label = draft.label { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
      DraftQuote(text: draft.text)
        .overlay(alignment: .topTrailing) { DraftCopyButton(text: draft.text).padding(6) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(draft.label.map { "Draft: \($0)" } ?? "Draft")
  }
}

/// A draft's Markdown beside a quote bar, on a rounded background.
struct DraftQuote: View {
  /// A taller draft scrolls inside the quote, so the Action stays near the Summary.
  static let maxHeight: CGFloat = 240

  let text: String

  var body: some View {
    HStack(spacing: 0) {
      QuoteBar()
      ScrollView {
        // The trailing padding leaves room for the copy button.
        MarkdownView(text: text)
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
  }
}

struct DraftCopyButton: View {
  static let copiedSeconds = 1.5

  let text: String
  @State private var copied = false

  var body: some View {
    Button {
      DraftCopy.copy(text)
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
