/// GitHub allows an account 100 event subscriptions at a time and keeps each for 24 hours. gh 2.105.0 and later
/// suggests `gh event listen` after commands such as `gh pr view`. Each listen takes one subscription. sbd
/// watches PRs itself, so a session never needs one.
public enum EventSubscriptions {
  /// The guidance that every session, Manager conversation, and the operator get. The operator reads it in the
  /// Manager folder's CLAUDE.md, so its own prompt does not repeat it.
  public static let guidance =
    "To wait for a PR's checks, reviews, approval, merge, merge queue, or deploy, set a wait with `sb wait` or the `set_wait` tool. Don't run `gh event listen` or `gh event subscription create`, even when gh's output suggests it. Each one uses one of the account's 100 GitHub event subscriptions for 24 hours, and sbd already watches the PR."
}
