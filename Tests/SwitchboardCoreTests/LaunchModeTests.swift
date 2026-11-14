import Foundation
import SwitchboardCore
import Testing

private let reportedModes: [String?] = ["plan", "default", "acceptEdits", "auto", nil]
private let modesOutsidePlan = reportedModes.filter { $0 != PermissionMode.plan }

/// Each `autoMode` value with the mode that a launch outside plan mode passes for it.
private let fallbacks: [(autoMode: Bool?, mode: String?)] = [(true, "auto"), (false, nil), (nil, nil)]

@Suite struct LaunchModeTests {
  func session(planMode: Bool?, autoMode: Bool?) -> Session {
    var session = Session(id: "s1", name: "s", cwd: "/tmp", claudeSessionId: "c", created: 0)
    session.planMode = planMode
    session.autoMode = autoMode
    return session
  }

  /// A first launch that claude left before its first prompt wrote no transcript. Its relaunch is not a resume.
  /// It passes plan whatever mode was reported.
  @Test(arguments: [true, false, nil] as [Bool?], reportedModes)
  func aFirstLaunchOfAPlanSessionPassesPlan(autoMode: Bool?, lastReported: String?) {
    let s = session(planMode: true, autoMode: autoMode)

    #expect(PermissionMode.forLaunch(s, resume: false, lastReported: lastReported) == "plan")
  }

  @Test(arguments: [true, false, nil] as [Bool?])
  func aResumeOfAPlanSessionThatLastReportedPlanPassesPlan(autoMode: Bool?) {
    let s = session(planMode: true, autoMode: autoMode)

    #expect(PermissionMode.forLaunch(s, resume: true, lastReported: "plan") == "plan")
  }

  /// A nil mode follows only a launch that passed none, after the session left plan mode under --no-auto. It does
  /// not bring plan mode back.
  @Test(arguments: modesOutsidePlan, fallbacks)
  func aResumeOfAPlanSessionThatLeftPlanModeFallsBackToItsAutoMode(
    lastReported: String?, fallback: (autoMode: Bool?, mode: String?)
  ) {
    let s = session(planMode: true, autoMode: fallback.autoMode)

    #expect(PermissionMode.forLaunch(s, resume: true, lastReported: lastReported) == fallback.mode)
  }

  /// A session that the user switched into plan mode with Shift+Tab keeps the behavior it had before planMode.
  @Test(arguments: [false, nil] as [Bool?], fallbacks)
  func aSessionWithoutPlanModeNeverPassesPlan(planMode: Bool?, fallback: (autoMode: Bool?, mode: String?)) {
    let s = session(planMode: planMode, autoMode: fallback.autoMode)

    for resume in [false, true] {
      for lastReported in reportedModes {
        #expect(
          PermissionMode.forLaunch(s, resume: resume, lastReported: lastReported) == fallback.mode,
          "resume \(resume), lastReported \(lastReported ?? "nil")")
      }
    }
  }
}
