import SwiftUI

enum ReduceMotion {
  /// The animation of a scroll to the focused row. It is nil when the system's Reduce Motion setting is on.
  /// The list then jumps.
  static func scrollAnimation(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .default }
}

extension ScrollViewProxy {
  /// Animates the scroll to `id` unless `reduceMotion` is true.
  func scrollTo(_ id: some Hashable, reduceMotion: Bool) {
    withAnimation(ReduceMotion.scrollAnimation(reduceMotion)) { scrollTo(id) }
  }
}
