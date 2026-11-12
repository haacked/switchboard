import SwiftUI

extension EventModifiers {
  /// SwiftUI's `.function`, which macOS 12 deprecates. AppKit still sets the
  /// flag on arrow keys. SwiftUI passes it on in a key press's modifiers.
  static let functionKey = EventModifiers(rawValue: 64)
}
