import SwiftUI
import SwitchboardCore

/// The box of an option: a rounded rectangle like a callout's, in neutral
/// colors so that it never reads as a warning or a note. A prominent box is
/// filled with the accent color. A ticked box has an accent border.
struct OptionCardChrome<Content: View>: View {
  var prominent = false
  var ticked = false
  var pressed = false
  /// A box that holds its own controls, such as a text field, doesn't highlight on hover.
  var interactive = true
  @ViewBuilder let content: Content
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8)
    content
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      // The opaque base keeps the box neutral inside a tinted card, such as a held question's.
      .background(shape.fill(fill).background(shape.fill(.background)))
      .overlay(shape.strokeBorder(border, lineWidth: ticked ? 1.5 : 1))
      .contentShape(shape)
      // A custom button style doesn't dim a disabled button by itself.
      .opacity(isEnabled ? 1 : 0.5)
      .onHover { hovering = interactive && $0 }
  }

  private var fill: Color {
    let lit = isEnabled && (pressed || hovering)
    if prominent { return Color.accentColor.opacity(pressed ? 0.75 : lit ? 0.88 : 1) }
    return Color.primary.opacity(pressed ? 0.12 : lit ? 0.08 : 0.04)
  }

  private var border: Color {
    if prominent { return .clear }
    if ticked { return .accentColor }
    return Color.primary.opacity(isEnabled && hovering ? 0.3 : 0.18)
  }
}

/// A button drawn as an option's box. The whole box takes the click.
struct OptionCardStyle: ButtonStyle {
  var prominent = false
  var ticked = false

  func makeBody(configuration: Configuration) -> some View {
    OptionCardChrome(prominent: prominent, ticked: ticked, pressed: configuration.isPressed) {
      configuration.label
    }
  }
}

/// What an option's box shows: a checkbox or radio for a pick, the title,
/// the description and a note under it, and a chevron for an option that
/// acts on a click.
struct OptionCardLabel: View {
  enum Mark {
    /// The click acts at once.
    case go
    case radio(Bool)
    case checkbox(Bool)
    case none
  }

  let mark: Mark
  let title: String
  var description: String?
  var note: String?
  var tag: String?
  var shortcut = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      switch mark {
      case .radio(let on): pickMark(on ? "largecircle.fill.circle" : "circle", on: on)
      case .checkbox(let on): pickMark(on ? "checkmark.square.fill" : "square", on: on)
      case .go, .none: EmptyView()
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(title).fontWeight(.semibold)
          if let tag {
            Text(tag).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
              .overlay(Capsule().strokeBorder(.secondary))
              .foregroundStyle(.secondary)
          }
        }
        if let description, !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary) }
        if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if shortcut { Text("⇧⌘↩").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
      if case .go = mark {
        Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
  }

  private func pickMark(_ symbol: String, on: Bool) -> some View {
    Image(systemName: symbol).font(.body).foregroundStyle(
      on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    )
    .accessibilityHidden(true)
  }
}

extension View {
  /// Gives the view ⌘⇧Return when `on`. One control per card owns it.
  @ViewBuilder
  func primaryShortcut(_ on: Bool) -> some View {
    if on { keyboardShortcut(OptionButton.primaryShortcut) } else { self }
  }
}

/// The ticked options of a multi-select card, by 1-based number. The picks
/// belong to the item that the user saw, so a new item starts with none.
struct OptionPicks: Equatable {
  private(set) var ref: String
  /// The option that the user ticked at each number.
  private var ticked: [Int: TriageOption] = [:]

  init(ref: String = "") { self.ref = ref }

  mutating func toggle(_ number: Int, _ option: TriageOption) {
    if ticked.removeValue(forKey: number) == nil { ticked[number] = option }
  }

  /// These picks when they belong to the item, else none. A rule can remove
  /// or replace an option without a change to the item's ref. This keeps a
  /// pick only while its number still holds the option that the user ticked.
  /// That option must also still be tickable.
  func on(_ item: TriageItem) -> OptionPicks {
    guard item.ref == ref else { return OptionPicks(ref: item.ref) }
    var kept = self
    kept.ticked = ticked.filter { number, option in
      item.options.indices.contains(number - 1) && item.options[number - 1] == option && item.isTickable(option)
    }
    return kept
  }

  func contains(_ number: Int) -> Bool { ticked[number] != nil }

  var canSubmit: Bool { !ticked.isEmpty }

  /// The picks as `choose` names them, in the options' order.
  var keys: [String] { ticked.keys.sorted().map(String.init) }

  static let prompt = "Tick the options that apply."

  /// What Submit sends, which its box shows because it sends text as the user.
  func effect(in item: TriageItem) -> String {
    let chosen = (try? item.picks(keys)) ?? []
    guard !chosen.isEmpty else { return Self.prompt }
    guard chosen.count > 1, chosen[0].action == .send else { return Triage.combined(chosen).effect(mergeMethod: nil) }
    // `effect` puts the text on one line. Several messages read better as the list that they send.
    return "Sends:\n" + chosen.map { "- \(oneLine($0.message ?? $0.label, max: 200))" }.joined(separator: "\n")
  }
}

/// A card's options as full-width boxes, stacked like its callouts. A click
/// on a box runs its option. On a multi-select card the user ticks boxes and
/// then clicks Submit, which sends the picks as one reply.
struct OptionList: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let item: TriageItem
  /// Typed replies by option index.
  @State private var replies: [Int: String] = [:]
  @State private var picks = OptionPicks()

  /// The picks for the item on screen. A pick made on another item, such as
  /// the session's last card, is not one.
  private var current: OptionPicks { picks.on(item) }

  enum ShortcutOwner: Equatable {
    case option(Int)
    case submit
    case none
  }

  /// The control that ⌘⇧Return clicks. A multi-select card's recommended
  /// option is a checkbox, so Submit takes the shortcut there.
  static func shortcutOwner(_ item: TriageItem) -> ShortcutOwner {
    if item.hasTickable { return .submit }
    return item.primaryIndex.map(ShortcutOwner.option) ?? .none
  }

  var body: some View {
    let owner = Self.shortcutOwner(item)
    let primary = item.primaryIndex
    VStack(alignment: .leading, spacing: 8) {
      ForEach(item.options.indices, id: \.self) { i in
        let option = item.options[i]
        if option.action == .reply {
          ReplyOption(
            session: session, ref: item.ref, number: i + 1, option: option,
            text: Binding(get: { replies[i, default: ""] }, set: { replies[i] = $0 }))
        } else if item.isTickable(option) {
          tickBox(i, option)
        } else {
          OptionButton(
            session: session, ref: item.ref, number: i + 1, option: option, primary: i == primary,
            shortcut: owner == .option(i))
        }
      }
      if owner == .submit { submit }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func tickBox(_ i: Int, _ option: TriageOption) -> some View {
    let ticked = current.contains(i + 1)
    return Button {
      picks = current
      picks.toggle(i + 1, option)
    } label: {
      OptionCardLabel(
        mark: .checkbox(ticked), title: option.label, description: option.detail,
        tag: option.recommended ? "Recommended" : nil)
    }
    .buttonStyle(OptionCardStyle(ticked: ticked))
    .accessibilityLabel(option.recommended ? "\(option.label), recommended" : option.label)
    .accessibilityHint(option.detail ?? "")
    .accessibilityAddTraits(ticked ? .isSelected : [])
  }

  private var submit: some View {
    let picks = current
    return Button {
      model.choose(session.id, ref: item.ref, picks: picks.keys)
    } label: {
      OptionCardLabel(mark: .go, title: "Submit", note: picks.effect(in: item), shortcut: picks.canSubmit)
    }
    .buttonStyle(OptionCardStyle(prominent: picks.canSubmit))
    .disabled(!picks.canSubmit || model.choosing.contains("\(session.id)/picks"))
    .primaryShortcut(true)
  }
}

/// An option's box. A click runs the option's action. The main option is
/// filled. The option that owns the shortcut answers ⌘⇧Return.
struct OptionButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  let primary: Bool
  var shortcut = false

  static let primaryShortcut = KeyboardShortcut(.return, modifiers: [.command, .shift])

  var body: some View {
    let effect = option.effect(mergeMethod: session.pr?.mergeMethod)
    Button {
      model.choose(session.id, ref: ref, option: number, action: option.action)
    } label: {
      OptionCardLabel(
        mark: .go, title: option.label, description: option.detail,
        note: option.showsEffect ? effect : nil, shortcut: shortcut)
    }
    .buttonStyle(OptionCardStyle(prominent: primary))
    .disabled(
      model.choosing.contains("\(session.id)/\(number)")
        || (option.action.isMerge && model.merging.contains(session.id))
    )
    .help(effect)
    .accessibilityLabel(option.accessibilityLabel(pr: session.pr?.number))
    .accessibilityHint(option.accessibilityHint(mergeMethod: session.pr?.mergeMethod))
    .primaryShortcut(shortcut)
  }
}

/// A choice that needs typing: the option's box holds its title, its
/// description, a field, and a Send button.
struct ReplyOption: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let ref: String
  let number: Int
  let option: TriageOption
  @Binding var text: String

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    OptionCardChrome(interactive: false) {
      VStack(alignment: .leading, spacing: 8) {
        // The text field reads the whole label.
        OptionCardLabel(mark: .none, title: option.label, description: option.detail).accessibilityHidden(true)
        HStack {
          TextField(option.placeholder ?? option.label, text: $text)
            .textFieldStyle(.roundedBorder)
            .onSubmit(send)
            .accessibilityLabel(option.label)
            .accessibilityHint(option.detail ?? "")
          Button("Send", action: send)
            .disabled(trimmed.isEmpty || model.choosing.contains("\(session.id)/\(number)"))
            .accessibilityLabel("Send: \(option.label)")
        }
      }
    }
  }

  private func send() {
    guard !trimmed.isEmpty else { return }
    model.choose(session.id, ref: ref, option: number, action: .reply, text: trimmed)
    text = ""
  }
}
