import SwiftUI
import SwitchboardCore

/// How many sessions run at once, with a menu to change the limit.
struct LimitMenu: View {
  @EnvironmentObject var model: BoardModel

  static let choices = [1, 2, 3, 4, 6, 8]

  var body: some View {
    if let status = model.limit {
      Menu {
        Button("Unlimited") { model.setLimit(nil) }
          .disabled(status.cap == nil)
        ForEach(Self.choices, id: \.self) { n in
          Button("\(n)") { model.setLimit(n) }
            .disabled(status.cap == n)
        }
      } label: {
        Label(Self.label(status), systemImage: "square.stack.3d.up")
          .labelStyle(.titleAndIcon)
      }
      .help("How many sessions run at once. A start past the limit is held in Waiting")
    }
  }

  /// The toolbar text: the running count, the limit when there is one, and
  /// the held count when above 0.
  static func label(_ status: LiveStatus) -> String {
    var text = "Running \(status.live.count)"
    if let cap = status.cap { text += " of \(cap)" }
    if !status.queued.isEmpty { text += " · \(status.queued.count) held" }
    return text
  }
}
