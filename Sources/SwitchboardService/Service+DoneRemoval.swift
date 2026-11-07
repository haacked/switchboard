import Foundation
import SwitchboardCore

extension Service {
  /// `rm-done` removes every Done session through `rm`, with the arguments
  /// that the Done delete icon sends: the worktree when `worktree` is set and
  /// sbd made it, the branch only when the session's PR merged, and the
  /// remote branch only with the branch and `remote_branch`. Without
  /// `confirmed`, it runs `rm`'s checks and returns a `DoneRemovalPlan`. With
  /// `confirmed`, it removes each of `targets` that is still a removable Done
  /// session and returns a `DoneRemovalResult`. A target that fails is
  /// skipped with `rm`'s message, and the rest continue. git runs off the
  /// state queue, as it does for `rm`.
  func removeDone(_ args: JSON) throws -> JSON {
    let worktree = args["worktree"]?.bool == true
    let remoteBranch = args["remote_branch"]?.bool == true
    guard args["confirmed"]?.bool == true else {
      let ids = queue.sync { summaries().filter(\.isRemovableDone).map(\.id) }
      return try JSON(encoding: planDoneRemoval(ids, worktree: worktree, remoteBranch: remoteBranch))
    }
    guard let targets = args["targets"]?.array?.compactMap(\.string) else {
      throw APIError("rm-done needs targets with confirmed")
    }
    var result = DoneRemovalResult(removed: [], skipped: [], partial: [])
    for id in targets {
      let target: DoneTarget
      switch doneTarget(id, worktree: worktree, remoteBranch: remoteBranch) {
      case .failure(let skip):
        result.skipped.append(skip.skip)
        continue
      case .success(let found):
        target = found
      }
      do {
        _ = try remove([
          "session": .string(id), "worktree": .bool(target.worktree), "branch": .bool(target.branch),
          "remote_branch": .bool(target.remoteBranch),
        ])
        result.removed.append(id)
      } catch {
        let skip = DoneRemovalPlan.Skip(id: id, name: target.session.name, reason: "\(error)")
        // `rm` throws after it forgets the session when only the branch or the remote branch stays.
        if queue.sync(execute: { entries[id] == nil }) {
          result.removed.append(id)
          result.partial.append(skip)
        } else {
          result.skipped.append(skip)
        }
      }
    }
    return try JSON(encoding: result)
  }

  /// Sorts the sessions into those that `rm` would remove and those it
  /// refuses, by running `rm`'s checks. The checks only read git, so they run
  /// concurrently.
  private func planDoneRemoval(_ ids: [String], worktree: Bool, remoteBranch: Bool) -> DoneRemovalPlan {
    let outcomes: [Result<DoneRemovalPlan.Item, Skipped>] = concurrentMap(ids) { id in
      switch doneTarget(id, worktree: worktree, remoteBranch: remoteBranch) {
      case .failure(let skipped):
        return .failure(skipped)
      case .success(let t):
        do {
          let checked = try checkRemoval(
            t.session, pr: t.pr, sharedWith: t.sharedWith,
            folderGone: !FileManager.default.fileExists(atPath: t.session.cwd), worktree: t.worktree,
            branch: t.branch)
          return .success(
            .init(
              id: id, name: t.session.name, pr: t.pr?.number, worktree: t.worktree ? t.session.cwd : nil,
              branch: checked.branch?.name, remoteBranch: t.remoteBranch && (checked.branch != nil || !checked.supacode)
            ))
        } catch {
          return .failure(Skipped(skip: .init(id: id, name: t.session.name, reason: "\(error)")))
        }
      }
    }
    var plan = DoneRemovalPlan(remove: [], skip: [])
    for outcome in outcomes {
      switch outcome {
      case .success(let item): plan.remove.append(item)
      case .failure(let skipped): plan.skip.append(skipped.skip)
      }
    }
    return plan
  }

  private struct DoneTarget {
    var session: Session
    var pr: PullRequest?
    var sharedWith: String?
    var worktree: Bool
    var branch: Bool
    var remoteBranch: Bool
  }

  private struct Skipped: Error {
    var skip: DoneRemovalPlan.Skip
  }

  /// The arguments of the Done delete icon's `rm` for the session, without
  /// running git. A session that is gone or no longer a removable Done
  /// session fails with the reason.
  private func doneTarget(_ id: String, worktree: Bool, remoteBranch: Bool) -> Result<DoneTarget, Skipped> {
    queue.sync {
      guard let e = entries[id] else {
        return .failure(Skipped(skip: .init(id: id, name: id, reason: "\(id) no longer exists")))
      }
      let s = e.session
      guard summary(id).isRemovableDone else {
        return .failure(Skipped(skip: .init(id: id, name: s.name, reason: "\(s.name) is no longer in Done")))
      }
      do {
        try checkTodos(id, resolving: [])
      } catch {
        let reason = (error as? OpenTodoError).map { "\(s.name) has an open to-do: \($0.list)" } ?? "\(error)"
        return .failure(Skipped(skip: .init(id: id, name: s.name, reason: reason)))
      }
      let removesWorktree = worktree && s.repo != nil
      let removesBranch = removesWorktree && s.branch != nil && e.facts.pr?.state == .merged
      return .success(
        DoneTarget(
          session: s, pr: e.facts.pr, sharedWith: sharedSession(s), worktree: removesWorktree,
          branch: removesBranch, remoteBranch: removesBranch && remoteBranch))
    }
  }
}
