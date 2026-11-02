import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct PRStatusColors {
  // The switch has no default, so a new PRStatus case fails to build until it gets a color here.
  func expected(_ status: PRStatus) -> Color {
    switch status {
    case .approved: .green
    case .changesRequested: .red
    case .reviewRequired, .notApproved: .blue
    case .merged: .purple
    case .draft, .closed: .gray
    }
  }

  @Test(arguments: PRStatus.allCases)
  func mapsToItsColor(status: PRStatus) {
    #expect(status.color == expected(status))
  }

  @Test func reviewStatesAreNotTheNeedsYouColor() {
    for status in PRStatus.allCases {
      #expect(status.color != AttentionState.needsYou.color)
    }
  }
}
