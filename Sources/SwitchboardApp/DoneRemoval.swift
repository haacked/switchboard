import SwiftUI
import SwitchboardCore

/// The Delete All sheet's state: sbd checks every Done session, the user
/// confirms the plan, the app removes the sessions one at a time, and the
/// sheet shows what happened.
enum DoneRemoval: Equatable {
  case checking
  case confirming(DoneRemovalPlan)
  case removing(DoneRemovalPlan, done: Int)
  case finished(DoneRemovalResult)
}

enum DoneRemovalText {
  static func title(_ plan: DoneRemovalPlan) -> String {
    switch plan.remove.count {
    case 0: "No Done session can be deleted"
    case 1: "Delete 1 Done session?"
    case let n: "Delete \(n) Done sessions?"
    }
  }

  static func progress(done: Int, total: Int) -> String { "Removing \(min(done + 1, total)) of \(total)…" }

  static func summary(removed: Int, skipped: Int) -> String {
    skipped == 0 ? "Removed \(removed)" : "Removed \(removed), skipped \(skipped)"
  }

  static func deletes(_ item: DoneRemovalPlan.Item) -> String {
    var parts = ["session"]
    if item.worktree != nil { parts.append("worktree") }
    if item.branch != nil { parts.append("branch") }
    if item.remoteBranch { parts.append("remote branch") }
    return englishList(parts)
  }
}

extension BoardModel {
  /// The arguments of the Done delete icon's `rm`: the worktree, and the
  /// branch and the remote branch when the PR merged.
  nonisolated static let doneRemovalArgs: [String: JSON] = ["worktree": true, "remote_branch": true]

  nonisolated static let unreadOrgReason = "sbd hasn't read its org yet"
  nonisolated static let hiddenOrgReason = "hidden by the org filter"
  nonisolated static let unlistedReason = "no longer listed"

  /// Why Delete All may not remove the session now, or nil when it may.
  func removalRefusal(_ id: String) -> String? {
    if removableIDs.contains(id) { return nil }
    if shownIDs.contains(id) { return Self.unreadOrgReason }
    return allBoard.contains { $0.id == id } ? Self.hiddenOrgReason : Self.unlistedReason
  }

  /// Asks sbd which Done sessions it would remove and which it would skip.
  /// The plan leaves out the sessions that the org filter hides. Under a
  /// filter, a shown session whose org sbd hasn't read yet moves from the
  /// remove list to the skip list.
  func checkDoneRemoval() {
    guard doneRemoval == nil else { return }
    doneRemoval = .checking
    perform(
      "rm-done", Self.doneRemovalArgs,
      then: { value in
        guard self.doneRemoval == .checking else { return }
        do {
          var plan = try JSONCoding.convert(value, to: DoneRemovalPlan.self)
          let shown = self.shownIDs
          let removable = self.removableIDs
          let unreadIDs = shown.subtracting(removable)
          let unread = plan.remove.filter { unreadIDs.contains($0.id) }
          plan.remove.removeAll { !removable.contains($0.id) }
          plan.skip.removeAll { !shown.contains($0.id) }
          plan.skip += unread.map { .init(id: $0.id, name: $0.name, reason: Self.unreadOrgReason) }
          self.doneRemoval = .confirming(plan)
        } catch {
          self.actionError = "rm-done: \(error)"
        }
      },
      finally: { if self.doneRemoval == .checking { self.doneRemoval = nil } })
  }

  /// Removes the plan's sessions one request at a time, so the sheet can show
  /// progress. sbd checks each session again. A session that fails its
  /// checks, or left Done, is skipped, and the rest continue.
  func removeDone(_ plan: DoneRemovalPlan) {
    guard case .confirming = doneRemoval else { return }
    doneRemoval = .removing(plan, done: 0)
    let send = send
    Task.detached {
      var result = DoneRemovalResult(removed: [], skipped: plan.skip, partial: [])
      for (n, item) in plan.remove.enumerated() {
        // A filter change after the plan can hide a session. The loop checks each one just before its send.
        if let refusal = await MainActor.run(body: { self.removalRefusal(item.id) }) {
          result.skipped.append(.init(id: item.id, name: item.name, reason: refusal))
          await MainActor.run { self.doneRemoval = .removing(plan, done: n + 1) }
          continue
        }
        var args = Self.doneRemovalArgs
        args["confirmed"] = true
        args["targets"] = [.string(item.id)]
        do {
          result.add(try JSONCoding.convert(try send("rm-done", args), to: DoneRemovalResult.self))
        } catch {
          result.skipped.append(.init(id: item.id, name: item.name, reason: "\(error)"))
        }
        await MainActor.run { self.doneRemoval = .removing(plan, done: n + 1) }
      }
      await MainActor.run { [result] in
        self.doneRemoval = .finished(result)
        self.deselect(result.removed)
        self.refresh(followups: true)
      }
    }
  }
}

/// Opens the Delete All sheet. It is off while no session can be deleted from
/// Done, and while a Delete All is open.
struct DeleteAllDoneButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button {
      model.checkDoneRemoval()
    } label: {
      Label("Delete All…", systemImage: "trash")
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .disabled(!model.board.contains(where: \.isRemovableDone) || model.doneRemoval != nil)
    .help("Delete every Done session, with its worktree, and its branch when the PR merged…")
    .accessibilityIdentifier("delete-all-done")
  }
}

struct DoneRemovalSheet: View {
  @EnvironmentObject var model: BoardModel
  let state: DoneRemoval

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch state {
      case .checking:
        ProgressView("Checking the Done sessions…")
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { model.doneRemoval = nil }.keyboardShortcut(.cancelAction)
        }
      case .confirming(let plan):
        Text(DoneRemovalText.title(plan)).font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(plan.remove, id: \.id) { item in
              VStack(alignment: .leading, spacing: 2) {
                Text(item.name + (item.pr.map { "  #\($0)" } ?? "")).fontWeight(.medium)
                Text("Deletes the \(DoneRemovalText.deletes(item))").font(.caption).foregroundStyle(.secondary)
                if let worktree = item.worktree {
                  Text(worktree).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }
            }
            SkipList(title: "Stays in Done", skips: plan.skip)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        Text(
          "Each session's claude stops and its terminals close. The conversation transcripts stay. sbd checks each session again before it deletes it."
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { model.doneRemoval = nil }.keyboardShortcut(.cancelAction)
          Button("Delete \(plan.remove.count)", role: .destructive) { model.removeDone(plan) }
            .disabled(plan.remove.isEmpty)
        }
      case .removing(let plan, let done):
        ProgressView(value: Double(done), total: Double(max(plan.remove.count, 1))) {
          Text(DoneRemovalText.progress(done: done, total: plan.remove.count))
        }
      case .finished(let result):
        Text(DoneRemovalText.summary(removed: result.removed.count, skipped: result.skipped.count)).font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            SkipList(title: "Removed, with something kept", skips: result.partial)
            SkipList(title: "Skipped", skips: result.skipped)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 360)
        HStack {
          Spacer()
          Button("Done") { model.doneRemoval = nil }.keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding()
    .frame(width: 520)
    .interactiveDismissDisabled(isRemoving)
  }

  private var isRemoving: Bool {
    if case .removing = state { return true }
    return false
  }
}

private struct SkipList: View {
  let title: String
  let skips: [DoneRemovalPlan.Skip]

  var body: some View {
    if !skips.isEmpty {
      Text(title).font(.subheadline.bold()).padding(.top, 4)
      ForEach(skips, id: \.id) { skip in
        VStack(alignment: .leading, spacing: 2) {
          Text(skip.name).fontWeight(.medium)
          Text(skip.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
  }
}
