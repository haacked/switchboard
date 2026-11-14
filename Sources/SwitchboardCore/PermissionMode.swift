/// Claude Code's permission modes, by the names that hook payloads carry.
public enum PermissionMode {
  public static let auto = "auto"
  public static let plan = "plan"
  /// The modes whose permission prompts offer to switch to auto mode: manual and accept edits.
  public static let offeringAutoMode: Set = ["default", "acceptEdits"]

  /// The card's action that allows the call and switches the session to auto mode.
  public static let approveLabel = "Approve and enable auto mode"
  /// What a card tells the user before they approve with auto mode.
  public static let autoModeNote = "auto mode: Claude's classifier decides further permissions"

  /// The mode that a launch of `session` passes with `--permission-mode`, or
  /// nil for none. `resume` says whether the launch resumes a transcript.
  /// `lastReported` is the mode that claude or the last launch reported.
  ///
  /// A session started in plan mode keeps plan mode until claude reports
  /// another mode, as after the user approves the plan. A resume before then
  /// passes plan again. A nil `lastReported` follows a launch that passed no
  /// mode. It does not bring plan mode back.
  public static func forLaunch(_ session: Session, resume: Bool, lastReported: String?) -> String? {
    if session.planMode == true, !resume || lastReported == plan { return plan }
    return session.autoMode == true ? auto : nil
  }

  /// The mode as Claude Code's status line names it. Its payloads call manual mode `default`.
  public static func title(_ mode: String) -> String {
    switch mode {
    case "default": "manual"
    case "acceptEdits": "accept edits"
    case "bypassPermissions": "bypass permissions"
    case "dontAsk": "don't ask"
    default: mode
    }
  }
}
