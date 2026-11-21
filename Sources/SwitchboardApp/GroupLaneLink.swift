import SwiftUI

/// A caption link in a group lane's label that opens `content` in a popover. `id` is the link's accessibility
/// identifier and click anchor. A caller that hides the link drops its `showing` with it, so the popover does not
/// open by itself when the link shows again.
struct GroupLaneLink<Content: View>: View {
  let title: String
  let help: String
  let label: String
  let id: String
  let width: CGFloat
  @ViewBuilder let content: () -> Content
  @State private var showing = false

  var body: some View {
    Button(title) { showing = true }
      .buttonStyle(.link).font(.caption).lineLimit(1)
      .help(help)
      .accessibilityLabel(label)
      .accessibilityIdentifier(id)
      .clickAnchor(id)
      .popover(isPresented: $showing, arrowEdge: .bottom) { content().frame(width: width) }
  }
}
