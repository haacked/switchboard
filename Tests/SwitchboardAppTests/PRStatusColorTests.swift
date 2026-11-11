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

@Suite struct QueueBadgeColors {
  // nil is GitHub's merge queue.
  @Test(arguments: [
    (TrunkQueueState?.some(.submitted), Color.purple), (.pending, .purple), (.testing, .purple), (.queued, .purple),
    (.merged, .purple), (.unknown, .purple), (nil, .purple), (.passed, .green), (.failing, .red), (.removed, .red),
  ])
  func tintsTheQueueState(_ queue: TrunkQueueState?, _ color: Color) {
    #expect(QueueBadge.color(for: queue) == color)
  }
}

@Suite struct PRTooltips {
  func summary(queue: TrunkQueueState? = nil, inMergeQueue: Bool? = nil) -> PRSummary {
    var pr = PRSummary(PullRequest(id: "PR_42", number: 42, url: "https://github.com/o/r/pull/42", repo: "o/r"))
    pr.title = "Fix"
    pr.status = .approved
    pr.queue = queue
    pr.inMergeQueue = inMergeQueue
    return pr
  }

  @Test func endsTheReviewStateWithTheQueuePhrase() {
    #expect(summary(queue: .testing).tooltip == "Approved, Trunk testing · o/r: Fix")
    #expect(summary(inMergeQueue: true).tooltip == "Approved, in the merge queue · o/r: Fix")
  }

  @Test func showsOnlyTheReviewStateOutsideAQueue() {
    #expect(summary().tooltip == "Approved · o/r: Fix")
  }
}
