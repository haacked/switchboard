import SwiftUI
import SwitchboardCore

/// What an option's row shows: a short title on its button, and beside it a
/// description. A label too long for a button moves beside it.
struct OptionRow {
  /// Below this width the description goes under its button.
  static let stackedWidth: CGFloat = 420
  static let separators = [": ", " — ", " – ", " - "]

  let title: String
  /// The part of the label that the button doesn't show.
  let lead: String?
  let description: String?

  init(option: TriageOption) {
    let label = option.label
    if label.count <= TriageCard.buttonLabelLength {
      (title, lead) = (label, nil)
    } else if let (head, tail) = Self.split(label) {
      (title, lead) = (head, tail)
    } else {
      // The action's name, such as Send or Merge.
      (title, lead) = (Triage.capitalized(option.action.rawValue), label)
    }
    description = Self.join(lead, option.detail)
  }

  static func stacked(width: CGFloat) -> Bool { width < stackedWidth }

  /// The label's head and tail at its first separator, when the head fits on a button.
  static func split(_ label: String) -> (String, String)? {
    guard
      let range = separators.compactMap({ label.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
    else { return nil }
    let head = label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    let tail = label[range.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !head.isEmpty, head.count <= TriageCard.buttonLabelLength, !tail.isEmpty else { return nil }
    return (head, tail)
  }

  static func join(_ lead: String?, _ detail: String?) -> String? {
    let detail = detail?.isEmpty == false ? detail : nil
    guard let lead else { return detail }
    guard let detail else { return lead }
    return lead.last.map(".?!".contains) == true ? "\(lead) \(detail)" : "\(lead). \(detail)"
  }
}

/// A card's options as rows: a compact button in a left column, and what the
/// option does beside it, or under it in a narrow pane.
struct OptionList: View {
  let session: SessionSummary
  let item: TriageItem
  @State private var stacked = false
  /// Typed replies by option index. Crossing the stacking width rebuilds
  /// every row. A draft kept in a row's own state would be lost.
  @State private var replies: [Int: String] = [:]

  var body: some View {
    let rows = item.options.map(OptionRow.init)
    // An option written twice is one main button.
    let primary = item.primary.flatMap { item.options.firstIndex(of: $0) }
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(item.options.indices, id: \.self) { i in
            VStack(alignment: .leading, spacing: 4) { cells(i, rows, primary: i == primary) }
          }
        }
      } else {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(item.options.indices, id: \.self) { i in
            GridRow { cells(i, rows, primary: i == primary) }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: Bool.self) {
      OptionRow.stacked(width: $0.size.width)
    } action: {
      stacked = $0
    }
  }

  /// The option's button, then the text beside it.
  @ViewBuilder
  private func cells(_ i: Int, _ rows: [OptionRow], primary: Bool) -> some View {
    let option = item.options[i]
    let title = OptionTitle(title: rows[i].title, titles: rows.map(\.title))
    if option.action == .reply {
      // The text field reads the whole label.
      title.foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        ReplyOption(
          session: session, ref: item.ref, number: i + 1, option: option,
          text: Binding(get: { replies[i, default: ""] }, set: { replies[i] = $0 }))
        if let description = rows[i].description {
          Text(description).foregroundStyle(.secondary).accessibilityHidden(true)
        }
      }
    } else {
      OptionButton(session: session, ref: item.ref, number: i + 1, option: option, title: title, primary: primary)
      // VoiceOver reads this text from the button's label and hint.
      VStack(alignment: .leading, spacing: 2) {
        if let description = rows[i].description { Text(description).foregroundStyle(.secondary) }
        if option.showsEffect {
          Text(option.effect(mergeMethod: session.pr?.mergeMethod)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(3)
        }
        if primary { Text("⇧⌘↩").font(.caption).foregroundStyle(.tertiary) }
      }
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityHidden(true)
    }
  }
}

/// A button's title, as wide as the card's widest title, so that the buttons
/// line up as one column.
struct OptionTitle: View {
  let title: String
  let titles: [String]

  var body: some View {
    ZStack(alignment: .leading) {
      ForEach(Array(titles.enumerated()), id: \.offset) { Text($1).fontWeight(.medium).hidden() }
      Text(title).fontWeight(.medium).lineLimit(1)
    }
  }
}
