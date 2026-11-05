import SwiftUI
import SwitchboardCore

/// The review card's Request review button. A click opens the suggested
/// reviewers, and nothing is requested until the user picks some and
/// clicks Request Review.
struct RequestReviewOption: View {
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  let primary: Bool
  @State private var picking = false

  var body: some View {
    OptionButton(session: session, ref: ref, number: number, option: option, primary: primary) { picking = true }
      .popover(isPresented: $picking, arrowEdge: .bottom) {
        ReviewerPicker(session: session, ref: ref, number: number, isPresented: $picking)
      }
  }
}

/// The suggested reviewers, each with a checkbox, and a button that requests
/// a review from the checked ones.
struct ReviewerPicker: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  @Binding var isPresented: Bool
  @State private var suggestions: [ReviewerSuggestion]?
  @State private var error: String?
  @State private var picked: Set<String> = []

  private var prRef: String { session.pr.map { "#\($0.number)" } ?? "the PR" }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Request a review of \(prRef)").font(.headline)
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(4)
      } else if let suggestions {
        ForEach(suggestions, id: \.login) { s in
          Toggle(isOn: checked(s.login)) {
            VStack(alignment: .leading, spacing: 1) {
              Text(s.login).fontWeight(.medium)
              Text(s.reason).font(.caption).foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
          .accessibilityLabel("\(s.login), \(s.reason)")
        }
      } else {
        ProgressView("Reading suggestions…").controlSize(.small)
      }
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
        Button("Request Review") {
          let reviewers = ReviewerPicker.chosen(suggestions ?? [], picked)
          model.choose(session.id, ref: ref, option: number, action: .requestReview, reviewers: reviewers)
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty || model.choosing.contains("\(session.id)/\(number)"))
      }
    }
    .padding()
    .frame(width: 320)
    .task {
      do {
        suggestions = try await model.reviewSuggestions(session.id)
      } catch {
        self.error = "\(error)"
      }
    }
  }

  private func checked(_ login: String) -> Binding<Bool> {
    Binding(
      get: { picked.contains(login) },
      set: { on in
        if on { picked.insert(login) } else { picked.remove(login) }
      })
  }

  /// The picked reviewers, in the order that the suggestions list them.
  static func chosen(_ suggestions: [ReviewerSuggestion], _ picked: Set<String>) -> [String] {
    suggestions.map(\.login).filter(picked.contains)
  }
}
