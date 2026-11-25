import SwiftUI

/// A row of a side panel or popover list: an optional icon, a title with an Open button, and a caption line that
/// can end with actions.
struct PanelRow<Actions: View>: View {
  struct Icon {
    var symbol: String
    var label: String
  }

  struct Open {
    var url: URL
    var help: String
    var label: String
    /// The Open button runs it before it opens the URL.
    var action: (() -> Void)? = nil
  }

  var icon: Icon?
  /// The title can be untrusted text, so it never renders as Markdown.
  let title: String
  var open: Open?
  let caption: String
  /// The most lines the title takes. Nil lets it wrap to its full height.
  var titleLines: Int? = nil
  var titleHelp: String? = nil
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let icon {
          Image(systemName: icon.symbol).foregroundStyle(.secondary).accessibilityLabel(icon.label)
        }
        Text(verbatim: title).textSelection(.enabled).lineLimit(titleLines)
          .fixedSize(horizontal: false, vertical: true)
          .help(titleHelp ?? "")
        Spacer(minLength: 0)
        if let open {
          Button("Open") {
            open.action?()
            NSWorkspace.shared.open(open.url)
          }
          .buttonStyle(.link)
          .help(open.help)
          .accessibilityLabel(open.label)
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: caption).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        actions()
      }
    }
  }
}

extension PanelRow where Actions == EmptyView {
  init(icon: Icon? = nil, title: String, open: Open?, caption: String) {
    self.init(icon: icon, title: title, open: open, caption: caption) { EmptyView() }
  }
}

/// A caption-size link in a Board lane's header that opens a popover with a scrolling list of `content`.
struct LanePopoverLink<Content: View>: View {
  let title: String
  let help: String
  let accessibilityLabel: String
  let identifier: String
  @ViewBuilder var content: () -> Content
  @State private var showing = false

  var body: some View {
    Button(title) { showing = true }
      .buttonStyle(.link).font(.caption).lineLimit(1)
      .help(help)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityIdentifier(identifier)
      .clickAnchor(identifier)
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        .frame(width: 420)
      }
      // `showing` stays true when the link leaves the view because its list is empty. Without the reset, the
      // popover would open by itself when the list fills again.
      .onDisappear { showing = false }
  }
}
