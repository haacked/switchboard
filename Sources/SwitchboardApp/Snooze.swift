import SwiftUI
import SwitchboardCore

/// The preset buttons and Pick a Time… of the Snooze and Pause menus. `choose` gets the end time of a preset.
struct TimePresetItems: View {
  let pick: () -> Void
  let choose: (Date) -> Void

  var body: some View {
    let presets = SnoozePresets.times(now: nowMs(), zone: .current)
    ForEach(Array(presets.enumerated()), id: \.offset) { index, shown in
      Button(shown.title) {
        // SwiftUI can build a context menu long before the click. A duration counts from the click.
        // A dated preset keeps the day that its title names, even when midnight passes before the click.
        let now = nowMs()
        let fresh = SnoozePresets.times(now: now, zone: .current)[index]
        let until = fresh.title == shown.title || shown.until <= now ? fresh.until : shown.until
        choose(Date(timeIntervalSince1970: Double(until) / 1000))
      }
    }
    Divider()
    Button("Pick a Time…", action: pick)
  }
}

/// The Snooze menu, with its presets and Pick a Time…, and Unsnooze while the session is snoozed. The session
/// menu shows it only for a session that `canSnooze` allows.
struct SnoozeMenuItems: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    let busy = model.snoozing.contains(session.id)
    Menu("Snooze") {
      TimePresetItems(
        pick: { model.pickingSnoozeTime = session.id },
        choose: { model.snooze(session.id, until: $0) })
    }
    .disabled(busy)
    if session.snoozedUntil != nil {
      Button("Unsnooze") { model.unsnooze(session.id) }.disabled(busy)
    }
  }
}

/// The sheet of Pick a Time…, which snoozes or pauses the session until a date and time that the user picks.
/// `verb` is "Snooze" or "Pause", and `close` clears the model's record of the open sheet.
struct UntilPicker: View {
  @EnvironmentObject var model: BoardModel
  let session: String
  let verb: String
  let apply: (Date) -> Void
  let close: () -> Void
  @State private var until = UntilPicker.nextFullHour(after: Date())

  static func nextFullHour(after now: Date) -> Date {
    let hour = Calendar.current.dateInterval(of: .hour, for: now)!.start
    return hour.addingTimeInterval(3600)
  }

  private var name: String { model.sessionNames.name(session) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("\(verb) \(name) until").font(.headline)
      DatePicker("Until", selection: $until, in: Date()..., displayedComponents: [.date, .hourAndMinute])
        .labelsHidden()
      // The confirm button turns off once the picked time passes, even while the sheet sits open.
      TimelineView(.periodic(from: .now, by: 1)) { context in
        HStack {
          Spacer()
          Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
          Button(verb) {
            apply(until)
            close()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(until <= context.date)
        }
      }
    }
    .padding(20)
    .frame(width: 320)
  }
}

/// A moon and the time the session's snooze ends, with the full time in its help.
struct SnoozeMark: View {
  let until: Int64

  var body: some View {
    let full = "Snoozed until \(Wait.formatTime(until))"
    Label(SnoozePresets.shortTime(until: until, now: nowMs(), zone: .current), systemImage: "moon.zzz")
      .labelStyle(.titleAndIcon)
      .font(.caption2)
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(.secondary)
      .help(full)
      .accessibilityLabel(full)
  }
}
