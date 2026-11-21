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
    .pointer(.link)
    .accessibilityLabel(Self.accessibilityLabel(text))
    .accessibilityAddTraits(.isLink)
    .accessibilityRemoveTraits(.isButton)
  }
}

/// The pointer shapes that views in the app ask for.
enum Pointer {
  case link
  case columnResize
}

extension View {
  /// Shows `pointer` while the pointer is over the view. macOS 14 has no `pointerStyle`. The pointer stays an arrow
  /// there.
  @ViewBuilder func pointer(_ pointer: Pointer) -> some View {
    if #available(macOS 15, *) {
      switch pointer {
      case .link: pointerStyle(.link)
      case .columnResize: pointerStyle(.columnResize)
      }
    } else {
      self
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
