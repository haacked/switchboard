import Foundation
import SwitchboardCore

/// The words after `sb schedule` that name a subcommand. A session with one
/// of these names is scheduled by its id.
let scheduleSubcommands = ["ls", "rm", "pause", "resume", "edit", "run"]

/// The flags of `sb schedule <session> --topup` that set the gate.
let topupFlags = ["--group", "--repo", "--target", "--template-file", "--rubric-file"]

/// `sb schedule <session> --every <interval> <prompt>` adds a schedule, and
/// `--topup` with each of `topupFlags` adds a gate to it.
/// `ls [<session>]` lists the schedules, `rm <id>` removes one, `pause <id>`
/// and `resume <id>` pause and resume one, `edit <id> [--every <interval>]
/// [<prompt>]` changes one, and `run <id>` makes one due now.
func scheduleCommand(_ a: Args) {
  let first = a.session("schedule")
  let result: JSON
  switch first {
  case "ls":
    guard a.positional.count <= 2 else { refuse(a.positional.dropFirst(2).joined(separator: " "), "schedule ls") }
    result = call("schedules", a.positional.count == 2 ? ["session": .string(a.positional[1])] : [:])
    if a.json { return printJSON(result) }
    let rows = decode(result, as: [ScheduleRow].self)
    if rows.isEmpty { print("No schedules.") }
    let names = gateGroupNames(rows.map(\.schedule))
    for r in rows {
      print("\(r.schedule.id)  \(r.name) (\(r.session))  \(scheduleText(r, groupNames: names))".printable)
    }
    return
  case "rm", "pause", "resume", "run":
    guard a.positional.count == 2 else { die("schedule \(first) needs a schedule id") }
    let id = JSON.string(a.positional[1])
    switch first {
    case "rm": result = call("remove-schedule", ["schedule": id])
    case "run": result = call("run-schedule", ["schedule": id])
    default: result = call("pause-schedule", ["schedule": id, "paused": .bool(first == "pause")])
    }
  case "edit":
    guard a.positional.count >= 2 else { die("schedule edit needs a schedule id") }
    var args: [String: JSON] = ["schedule": .string(a.positional[1])]
    // An empty prompt argument still goes to sbd, which refuses it and keeps the interval too.
    if a.positional.count > 2 { args["prompt"] = .string(a.positional.dropFirst(2).joined(separator: " ")) }
    if let every = a.values["--every"] { args["every"] = .string(every) }
    guard args.count > 1 else { die("schedule edit needs --every or a prompt") }
    args.merge(callerArg) { $1 }
    result = call("edit-schedule", args)
  default:
    let prompt = a.positional.dropFirst().joined(separator: " ")
    var args: [String: JSON] = ["session": .string(first), "by": .string(author.rawValue)]
    // A top-up's prompt is optional, and sbd stores a default for an empty one.
    if !(a.switches.contains("--topup") && prompt.isEmpty) { args["prompt"] = .string(prompt) }
    if let every = a.values["--every"] { args["every"] = .string(every) }
    if let gate = topupGate(a) { args["gate"] = gate }
    args.merge(callerArg) { $1 }
    result = call("schedule", args)
  }
  if a.json { return printJSON(result) }
  let row = decode(result, as: ScheduleRow.self)
  let names = gateGroupNames([row.schedule])
  print("\(first == "rm" ? "removed " : "")\(row.schedule.id)  \(scheduleText(row, groupNames: names))".printable)
}

/// The `gate` request of `sb schedule <session> --topup`, with the text of the template and rubric files, or nil
/// without `--topup`. It dies when a flag is missing, when a flag comes without `--topup`, or when a file can't be
/// read.
func topupGate(_ a: Args) -> JSON? {
  guard a.switches.contains("--topup") else {
    if let flag = topupFlags.first(where: { a.values[$0] != nil }) { die("\(flag) goes with --topup") }
    return nil
  }
  func need(_ flag: String) -> String {
    guard let value = a.values[flag] else { die("--topup needs \(flag)") }
    return value
  }
  func text(of flag: String) -> String {
    let value = need(flag)
    let path = URL(fileURLWithPath: value.expandingTilde).path
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { die("can't read \(flag) \(value)") }
    return text
  }
  let group = need("--group")
  let repo = need("--repo")
  let targetValue = need("--target")
  guard let target = Int(targetValue) else { die("--target needs a number of sessions, not \(targetValue)") }
  let template = text(of: "--template-file")
  let rubric = text(of: "--rubric-file")
  return [
    "group": .string(group), "repo": .string(repo), "target": .number(Double(target)), "template": .string(template),
    "rubric": .string(rubric),
  ]
}

/// The name of each group that a schedule's gate names, by id. sbd keeps the group's id in the gate, so a rename
/// shows the new name. A group that sbd no longer has, or a failed read, leaves the id.
func gateGroupNames(_ schedules: [Schedule]) -> [String: String] {
  guard schedules.contains(where: { $0.gate != nil }), let answer = try? client.call("group-ls"),
    let list = try? JSONCoding.convert(answer, to: GroupList.self)
  else { return [:] }
  return Dictionary(list.groups.map { ($0.id, $0.name) }) { first, _ in first }
}

/// The row's line with the status that sbd computed. An sbd older than the
/// status sends none, so the line falls back to the next run.
func scheduleText(_ r: ScheduleRow, groupNames: [String: String]) -> String {
  scheduleText(r.schedule, status: r.status?.text ?? r.schedule.nextText(), groupNames: groupNames)
}

/// The prompt on one line, then the interval, the status, the last result, and a gate's last check.
func scheduleText(_ s: Schedule, status: String, groupNames: [String: String]) -> String {
  let line = "\(oneLine(s.prompt))  \(s.timingText(status)) · \(s.lastText())"
  guard let gate = s.gate else { return line }
  return "\(line)  \(gate.statusText(groupName: groupNames[gate.group] ?? gate.group))"
}

/// The summary carries the facts that sbd's tick reads, so the status matches the one that sbd computes.
func printSchedules(_ s: SessionSummary) {
  let schedules = s.allSchedules
  let names = gateGroupNames(schedules)
  for schedule in schedules {
    let status = ScheduleStatus(schedule, hold: s.scheduleHold, now: nowMs())
    print("  schedule: \(schedule.id)  \(scheduleText(schedule, status: status.text, groupNames: names))".printable)
  }
}
