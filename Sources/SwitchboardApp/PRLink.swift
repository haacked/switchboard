import SwiftUI

/// A pull request shown as a link. A click opens `url` through the `openURL`
/// environment action, which opens the default browser unless a caller replaces it.
struct PRLink: View {
  let text: String
  let url: URL
  @Environment(\.openURL) private var openURL
  @State private var hovering = false

  static func accessibilityLabel(_ text: String) -> String { "Pull request \(text)" }

  var body: some View {
    Button {
      openURL(url)
    } label: {
      Text(verbatim: text).underline(hovering)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .modifier(LinkPointer())
    .accessibilityLabel(Self.accessibilityLabel(text))
    .accessibilityAddTraits(.isLink)
    .accessibilityRemoveTraits(.isButton)
  }
}

/// macOS 14 has no `pointerStyle`. The pointer stays an arrow there.
private struct LinkPointer: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(.link)
    } else {
      content
    }
  }
}

/// Where a Board card's label reserves room for its PR link. The card draws
/// the link over its button at these bounds. A button inside a button's
/// label does not get the click.
struct PRLinkBounds: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}
