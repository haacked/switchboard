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

/// The drafts of an Inbox message, each in a quote with a copy button. A draft that names a GitHub comment to
/// reply to is an editable field with its own Post button.
struct DraftsSection: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: item.drafts.count == 1 ? "Draft" : "Drafts")
      ForEach(Array(item.drafts.enumerated()), id: \.offset) { _, draft in
        if Self.usesReplyView(draft, in: item) {
          DraftReplyView(
            session: session.id, ref: item.ref, draft: draft,
            field: model.replyField(session: session.id, ref: item.ref, number: draft.number)
          )
          .id("\(item.ref)/\(draft.number)")
        } else {
          DraftView(draft: draft)
        }
      }
    }
  }

  /// Only the session's own card names a target. A summarizer's draft could carry a target copied from quoted text.
  static func usesReplyView(_ draft: InboxDraft, in item: TriageItem) -> Bool {
    draft.replyTo != nil && item.source == .session
  }
}

struct DraftView: View {
  let draft: InboxDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label = draft.label { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
      DraftQuote(text: draft.text)
        .overlay(alignment: .topTrailing) { DraftCopyButton(text: draft.text).padding(6) }
      if let caption = DraftReplyView.mode(for: draft).caption { DraftCaption(text: caption) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(draft.label.map { "Draft: \($0)" } ?? "Draft")
  }
}

/// A draft reply to a GitHub comment: the comment it answers, the user's edit of the session's text, and the
/// button that posts it as the user. Post has no keyboard shortcut, so only a click posts.
struct DraftReplyView: View {
  enum Mode: Equatable {
    /// The draft only copies. A reason says why its target can't take a post.
    case copyOnly(reason: String?)
    case checking
    case unresolved(error: String)
    /// The field posts. A failed post's error says why GitHub refused it.
    case editable(error: String?)
    case posting
    /// sbd can't tell whether GitHub got the reply. `thread` is the comment that it answers.
    case unknown(error: String, thread: String)
    case posted(text: String, url: String)

    /// The line under the draft that says what it waits for, or why it only copies.
    var caption: String? {
      switch self {
      case .copyOnly(let reason): reason
      case .checking: "Checking the comment on GitHub…"
      case .unknown: "sbd can't tell whether GitHub got the reply. Check again looks for it in the thread."
      default: nil
      }
    }

    var error: String? {
      switch self {
      case .unresolved(let error), .unknown(let error, _): error
      case .editable(let error): error
      default: nil
      }
    }

    var showsPostButton: Bool {
      switch self {
      case .copyOnly, .posting, .posted: false
      default: true
      }
    }

    /// sbd's `draft-post` accepts only a ready or a failed draft.
    var canPost: Bool {
      if case .editable = self { return true }
      return false
    }

    var checksAgain: Bool {
      switch self {
      case .unresolved, .unknown: true
      default: false
      }
    }

    /// A posting or unknown draft keeps its field read-only, so the text on screen is what sbd sent.
    var fieldEditable: Bool {
      switch self {
      case .checking, .unresolved, .editable: true
      default: false
      }
    }
  }

  /// `unknown` shows the field's text, because sbd's state doesn't carry the text that it sent. `posting` is the
  /// app's own request for the draft. sbd's state reaches the app one refresh after the press, so that request
  /// locks a postable field first.
  static func mode(for draft: InboxDraft, posting: Bool = false) -> Mode {
    let mode = mode(of: draft.post)
    return posting && draft.post.postable != nil ? .posting : mode
  }

  /// Post is on only for a postable draft whose text has more than blank lines. sbd accepts the same drafts.
  static func postEnabled(_ mode: Mode, text: String) -> Bool {
    mode.canPost && !TriageDrafts.trimBlankLines(text).isEmpty
  }

  private static func mode(of post: DraftPost) -> Mode {
    switch post {
    case .copyOnly(let reason): .copyOnly(reason: reason)
    case .checking: .checking
    case .unresolved(let error): .unresolved(error: error)
    case .ready: .editable(error: nil)
    case .failed(_, let error): .editable(error: error)
    case .posting: .posting
    case .unknown(let target, let error): .unknown(error: error, thread: target.url)
    case .posted(_, let url, let text): .posted(text: text, url: url)
    }
  }

  static let editorHeight: CGFloat = 120

  @EnvironmentObject var model: BoardModel
  let session: String
  let ref: String
  let draft: InboxDraft
  @ObservedObject var field: MessageField.Draft

  private var key: String { MessageDrafts.replyKey(session: session, ref: ref, number: draft.number) }

  private var mode: Mode { Self.mode(for: draft, posting: model.postingDrafts.contains(key)) }

  /// A refusal that sbd didn't record shows until sbd's state changes.
  private var shownError: String? { model.draftErrors[key] ?? mode.error }

  private var target: ResolvedTarget? { draft.post.target }

  var body: some View {
    let mode = mode
    Group {
      switch mode {
      case .copyOnly:
        DraftView(draft: draft)
      case .posted(let text, let url):
        posted(text: text, url: url)
      default:
        editor(mode)
      }
    }
    .onAppear {
      // An emptied field starts again with the session's text when it next appears.
      _ = model.replyDraft(session: session, ref: ref, number: draft.number, initial: draft.text)
    }
    .onChange(of: draft.post) { model.draftErrors[key] = nil }
    // A refused post leaves the field as it was, so VoiceOver would say nothing.
    .onChange(of: shownError) {
      if let error = shownError { AccessibilityNotification.Announcement(error).post() }
    }
  }

  private func posted(text: String, url: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let label = draft.label { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
      DraftQuote(text: text)
        .overlay(alignment: .topTrailing) { DraftCopyButton(text: text).padding(6) }
      if let destination = URL(string: url) {
        Link(destination: destination) { Label("Posted to GitHub", systemImage: "checkmark.circle.fill") }
          .font(.callout)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(draft.label.map { "Posted reply: \($0)" } ?? "Posted reply")
  }

  private func editor(_ mode: Mode) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let label = draft.label { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
      if let target { targetLine(target) }
      HStack(spacing: 0) {
        QuoteBar()
        TextEditor(text: $field.text)
          .font(.body)
          .scrollContentBackground(.hidden)
          .disabled(!mode.fieldEditable)
          .padding(.leading, 6)
          .padding(.trailing, 36)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, minHeight: Self.editorHeight, maxHeight: Self.editorHeight)
          .accessibilityLabel(target.map { "Reply to @\($0.author)" } ?? "Reply")
      }
      .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(alignment: .topTrailing) { DraftCopyButton(text: field.text).padding(6) }
      if let error = shownError {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let caption = mode.caption { DraftCaption(text: caption) }
      buttons(mode)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(draft.label.map { "Draft reply: \($0)" } ?? "Draft reply")
  }

  /// "Replies to @ann on a.swift line 3: ‘NOT over AND’", with the author linked to the comment.
  private func targetLine(_ target: ResolvedTarget) -> some View {
    var author = AttributedString("@\(target.author)")
    author.link = URL(string: target.url)
    var line = AttributedString("Replies to ") + author + AttributedString(" \(target.place)")
    if !target.excerpt.isEmpty { line += AttributedString(": ‘\(target.excerpt)’") }
    return Text(line).font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }

  private func buttons(_ mode: Mode) -> some View {
    WrappingRow(spacing: 8) {
      if mode == .posting {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Posting…").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      if mode.showsPostButton {
        Button("Post") { model.postDraft(session, ref: ref, number: draft.number, text: field.text) }
          .disabled(!Self.postEnabled(mode, text: field.text))
          .help("Post the text above to GitHub as you")
          .accessibilityLabel(target.map { "Post reply to \($0.author)" } ?? "Post reply")
          .accessibilityHint("Posts the text above to GitHub as you")
      }
      if mode.checksAgain {
        Button("Check again") { model.checkDraft(session, ref: ref, number: draft.number) }
          .accessibilityHint(
            target == nil ? "Reads the comment on GitHub again" : "Looks for the reply in the thread on GitHub")
      }
      if case .unknown(_, let thread) = mode, let destination = URL(string: thread) {
        Link("Open the thread", destination: destination)
      }
      if mode.fieldEditable, field.text != draft.text {
        Button("Use the session's text") { field.text = draft.text }
          .accessibilityHint("Replaces your edit with the text that the session drafted")
      }
    }
  }
}

private struct DraftCaption: View {
  let text: String

  var body: some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
