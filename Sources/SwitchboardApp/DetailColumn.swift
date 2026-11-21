import SwitchboardCore

/// What the window's detail column shows.
enum DetailColumn: Equatable {
  case multiSelection
  case followup(SessionSummary, Followup)
  case docket(SessionSummary, DocketSummary)
  case session(SessionSummary)
  case main(MainView)

  /// True for a main view that shows a list beside the current item's detail.
  var isListDetail: Bool {
    switch self {
    case .main(let view): view != .board
    default: false
    }
  }
}

extension BoardModel {
  var detailColumn: DetailColumn {
    if showsMultiSelectionPane { return .multiSelection }
    guard let s = selected else { return .main(mainView) }
    if let f = s.followup, f.started == nil { return .followup(s, f) }
    if let d = s.docket { return .docket(s, d) }
    return .session(s)
  }
}
