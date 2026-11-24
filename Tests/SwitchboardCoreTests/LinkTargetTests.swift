import Foundation
import Testing

@testable import SwitchboardCore

/// Example links of each kind that the link tests share. Every workspace, channel, and id is made up.
enum LinkFixtures {
  static let channel = "C0EXAMPLE01"
  static let dmChannel = "D0EXAMPLE01"
  /// The ts of a thread's first message, and the `p` segment of its link.
  static let rootTs = "1794965000.000100"
  static let rootP = "p1794965000000100"
  /// The ts of a reply in that thread, and the `p` segment of its link.
  static let replyTs = "1794965246.462679"
  static let replyP = "p1794965246462679"

  static let slackRoot = "https://example.slack.com/archives/\(channel)/\(rootP)"
  static let slackReply = "https://example.slack.com/archives/\(channel)/\(replyP)?thread_ts=\(rootTs)&cid=\(channel)"
  static let slackRootKey = "slack:example/\(channel)/\(rootTs)"
  /// The link of the message in the Evidence sample of a `slack_send_message` result.
  static let slackDM = "https://example.slack.com/archives/\(dmChannel)/\(replyP)"

  static let linear = "https://linear.app/example/issue/ENG-123/fix-the-flag-cache"
  static let hex = "0123456789abcdef0123456789abcdef"
  static let notion = "https://www.notion.so/example/Q4-Plan-\(hex)"
  static let googleId = "1AbCdEfGhIjKlMnOpQrStUvWxYz_-0123456789"
  static let google = "https://docs.google.com/document/d/\(googleId)/edit?usp=sharing"
  static let grafana = "https://grafana.example.com/d/abc123/api-latency?orgId=1&from=now-6h&to=now"

  static let githubPR = "https://github.com/example/widgets/pull/42"
}

/// One URL that the parser accepts, and the target it must give.
struct AcceptedLink: Sendable, CustomTestStringConvertible {
  var name: String
  var url: String
  var kind: LinkKind
  var key: String
  var title: String
  var channel: String? = nil
  var thread: String? = nil
  var messageTs: String? = nil

  var testDescription: String { name }
}

/// One URL that the parser refuses.
struct RefusedLink: Sendable, CustomTestStringConvertible {
  var name: String
  var url: String

  var testDescription: String { name }
}

private let ch = LinkFixtures.channel
private let rootTs = LinkFixtures.rootTs
private let replyTs = LinkFixtures.replyTs
private let rootP = LinkFixtures.rootP
private let replyP = LinkFixtures.replyP
private let hex = LinkFixtures.hex
private let gid = LinkFixtures.googleId

private func slack(
  _ name: String, _ url: String, workspace: String = "example", channel: String = LinkFixtures.channel,
  thread: String = LinkFixtures.rootTs, messageTs: String = LinkFixtures.rootTs
) -> AcceptedLink {
  AcceptedLink(
    name: name, url: url, kind: .slack, key: "slack:\(workspace)/\(channel)/\(thread)",
    title: "Slack thread in \(channel)", channel: channel, thread: thread, messageTs: messageTs)
}

private let acceptedSlack: [AcceptedLink] = [
  slack("slack root", "https://example.slack.com/archives/\(ch)/\(rootP)"),
  slack(
    "slack reply with thread_ts and cid",
    "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=\(rootTs)&cid=\(ch)",
    messageTs: replyTs),
  slack(
    "slack cid first, then thread_ts",
    "https://example.slack.com/archives/\(ch)/\(replyP)?cid=\(ch)&thread_ts=\(rootTs)",
    messageTs: replyTs),
  slack("slack with cid only", "https://example.slack.com/archives/\(ch)/\(rootP)?cid=\(ch)"),
  slack("slack with a fragment", "https://example.slack.com/archives/\(ch)/\(rootP)#message"),
  slack("slack uppercase scheme and host", "HTTPS://EXAMPLE.SLACK.COM/archives/\(ch)/\(rootP)"),
  slack("slack mixed-case host", "https://Example.Slack.com/archives/\(ch)/\(rootP)"),
  slack(
    "slack DM channel", "https://example.slack.com/archives/D0EXAMPLE01/\(replyP)", channel: "D0EXAMPLE01",
    thread: replyTs, messageTs: replyTs),
  slack(
    "slack workspace with a hyphen and digits", "https://my-team-2.slack.com/archives/\(ch)/\(rootP)",
    workspace: "my-team-2"),
  slack("slack all-digit channel", "https://example.slack.com/archives/0123456789/\(rootP)", channel: "0123456789"),
  slack(
    "slack workspace whose name contains grafana", "https://grafana.slack.com/archives/\(ch)/\(rootP)",
    workspace: "grafana"),
]

private let refusedSlack: [RefusedLink] = [
  RefusedLink(name: "slack http", url: "http://example.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(
    name: "slack look-alike suffix host", url: "https://example.slack.com.evil.example/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack look-alike evil-slack.com", url: "https://evil-slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack look-alike exampleslack.com", url: "https://exampleslack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack host with a trailing dot", url: "https://example.slack.com./archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack.com without a workspace", url: "https://slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(
    name: "slack two-label enterprise host", url: "https://acme.enterprise.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack app client link", url: "https://app.slack.com/client/T0EXAMPLE01/\(ch)"),
  RefusedLink(name: "slack host with an underscore", url: "https://my_team.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(
    name: "slack userinfo that names the workspace",
    url: "https://example.slack.com@evil.example/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack user", url: "https://someone@example.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack user and password", url: "https://someone:secret@example.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack port 443", url: "https://example.slack.com:443/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack port 8443", url: "https://example.slack.com:8443/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack encoded slash", url: "https://example.slack.com/archives/\(ch)%2F\(rootP)"),
  RefusedLink(name: "slack encoded digit", url: "https://example.slack.com/archives/\(ch)/p179496500000010%30"),
  RefusedLink(name: "slack encoded letter in archives", url: "https://example.slack.com/%61rchives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack extra segment", url: "https://example.slack.com/archives/\(ch)/\(rootP)/extra"),
  RefusedLink(name: "slack trailing slash", url: "https://example.slack.com/archives/\(ch)/\(rootP)/"),
  RefusedLink(name: "slack double slash", url: "https://example.slack.com//archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack channel link without a message", url: "https://example.slack.com/archives/\(ch)"),
  RefusedLink(name: "slack channel link with a slash", url: "https://example.slack.com/archives/\(ch)/"),
  RefusedLink(name: "slack archives alone", url: "https://example.slack.com/archives"),
  RefusedLink(name: "slack another first segment", url: "https://example.slack.com/messages/\(ch)/\(rootP)"),
  RefusedLink(name: "slack lowercase channel", url: "https://example.slack.com/archives/c0example01/\(rootP)"),
  RefusedLink(name: "slack channel with a hyphen", url: "https://example.slack.com/archives/C0EXAMPLE-01/\(rootP)"),
  RefusedLink(name: "slack p with 15 digits", url: "https://example.slack.com/archives/\(ch)/p179496500000010"),
  RefusedLink(name: "slack p with 17 digits", url: "https://example.slack.com/archives/\(ch)/p17949650000001000"),
  RefusedLink(name: "slack p with a letter", url: "https://example.slack.com/archives/\(ch)/p179496500000010a"),
  RefusedLink(name: "slack ts without p", url: "https://example.slack.com/archives/\(ch)/1794965000000100"),
  RefusedLink(name: "slack uppercase P", url: "https://example.slack.com/archives/\(ch)/P1794965000000100"),
  RefusedLink(
    name: "slack thread_ts with 4 decimals",
    url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=1794965000.0001"),
  RefusedLink(
    name: "slack thread_ts not a ts", url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=abc"),
  RefusedLink(name: "slack thread_ts empty", url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts="),
  RefusedLink(
    name: "slack thread_ts without a value", url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts"),
  RefusedLink(
    name: "slack thread_ts without the dot",
    url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=1794965000000100"),
  RefusedLink(
    name: "slack thread_ts with a trailing letter",
    url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=\(rootTs)x"),
  /// Two `thread_ts` values name no single thread.
  RefusedLink(
    name: "slack two thread_ts values",
    url: "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=\(rootTs)&thread_ts=1794960000.000200"),
  RefusedLink(name: "slack custom scheme", url: "slack://channel?team=T0EXAMPLE01&id=\(ch)"),
  RefusedLink(name: "slack without a scheme", url: "example.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(name: "slack protocol-relative", url: "//example.slack.com/archives/\(ch)/\(rootP)"),
  RefusedLink(
    name: "slack backslash host trick", url: "https://example.slack.com\\@evil.example/archives/\(ch)/\(rootP)"),
]

private let acceptedLinear: [AcceptedLink] = [
  AcceptedLink(
    name: "linear", url: "https://linear.app/example/issue/ENG-123", kind: .linear, key: "linear:example/ENG-123",
    title: "Linear ENG-123"),
  AcceptedLink(
    name: "linear with a slug", url: "https://linear.app/example/issue/ENG-123/fix-the-flag-cache", kind: .linear,
    key: "linear:example/ENG-123", title: "Linear ENG-123"),
  AcceptedLink(
    name: "linear with query and fragment", url: "https://linear.app/example/issue/ENG-123?foo=1#comment-0a1b2c",
    kind: .linear, key: "linear:example/ENG-123", title: "Linear ENG-123"),
  AcceptedLink(
    name: "linear uppercase scheme and host", url: "HTTPS://LINEAR.APP/Example/issue/ENG-123", kind: .linear,
    key: "linear:example/ENG-123", title: "Linear ENG-123"),
  AcceptedLink(
    name: "linear lowercase key", url: "https://linear.app/example/issue/eng-123", kind: .linear,
    key: "linear:example/ENG-123", title: "Linear ENG-123"),
  AcceptedLink(
    name: "linear team with a digit", url: "https://linear.app/my-team/issue/E2E-7", kind: .linear,
    key: "linear:my-team/E2E-7", title: "Linear E2E-7"),
]

private let refusedLinear: [RefusedLink] = [
  RefusedLink(name: "linear http", url: "http://linear.app/example/issue/ENG-123"),
  RefusedLink(name: "linear look-alike suffix host", url: "https://linear.app.evil.example/example/issue/ENG-123"),
  RefusedLink(name: "linear look-alike evil-linear.app", url: "https://evil-linear.app/example/issue/ENG-123"),
  RefusedLink(name: "linear www host", url: "https://www.linear.app/example/issue/ENG-123"),
  RefusedLink(name: "linear userinfo", url: "https://linear.app@evil.example/example/issue/ENG-123"),
  RefusedLink(name: "linear user", url: "https://someone@linear.app/example/issue/ENG-123"),
  RefusedLink(name: "linear port", url: "https://linear.app:443/example/issue/ENG-123"),
  RefusedLink(name: "linear encoded hyphen", url: "https://linear.app/example/issue/ENG%2D123"),
  RefusedLink(name: "linear encoded slash", url: "https://linear.app/example%2Fissue/ENG-123"),
  RefusedLink(name: "linear extra segment", url: "https://linear.app/example/issue/ENG-123/fix-the-cache/extra"),
  RefusedLink(name: "linear missing key", url: "https://linear.app/example/issue/"),
  RefusedLink(name: "linear missing key and slash", url: "https://linear.app/example/issue"),
  RefusedLink(name: "linear missing workspace", url: "https://linear.app/issue/ENG-123"),
  RefusedLink(name: "linear project page", url: "https://linear.app/example/project/ENG-123"),
  RefusedLink(name: "linear key with an underscore", url: "https://linear.app/example/issue/ENG_123"),
  RefusedLink(name: "linear key starting with a digit", url: "https://linear.app/example/issue/1ENG-123"),
  RefusedLink(name: "linear key without a number", url: "https://linear.app/example/issue/ENG-"),
  RefusedLink(name: "linear key with a letter in the number", url: "https://linear.app/example/issue/ENG-12a"),
  RefusedLink(name: "linear key without a hyphen", url: "https://linear.app/example/issue/ENG123"),
  RefusedLink(name: "linear slug with an underscore", url: "https://linear.app/example/issue/ENG-123/fix_the_cache"),
  RefusedLink(name: "linear workspace with a dot", url: "https://linear.app/exa.mple/issue/ENG-123"),
]

private let acceptedNotion: [AcceptedLink] = [
  AcceptedLink(
    name: "notion bare id", url: "https://www.notion.so/\(hex)", kind: .notion, key: "notion:\(hex)",
    title: "Notion page"),
  AcceptedLink(
    name: "notion with a slug", url: "https://www.notion.so/Q4-Plan-\(hex)", kind: .notion, key: "notion:\(hex)",
    title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion workspace and slug", url: "https://www.notion.so/example/Q4-Plan-\(hex)", kind: .notion,
    key: "notion:\(hex)", title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion workspace and bare id", url: "https://www.notion.so/example/\(hex)", kind: .notion,
    key: "notion:\(hex)", title: "Notion page"),
  AcceptedLink(
    name: "notion bare host", url: "https://notion.so/Q4-Plan-\(hex)", kind: .notion, key: "notion:\(hex)",
    title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion site", url: "https://example.notion.site/Q4-Plan-\(hex)", kind: .notion, key: "notion:\(hex)",
    title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion with pvs query", url: "https://www.notion.so/Q4-Plan-\(hex)?pvs=4", kind: .notion,
    key: "notion:\(hex)", title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion with view query and fragment", url: "https://www.notion.so/\(hex)?v=fedcba9876543210#block",
    kind: .notion, key: "notion:\(hex)", title: "Notion page"),
  AcceptedLink(
    name: "notion uppercase scheme host and id", url: "HTTPS://WWW.NOTION.SO/Q4-Plan-\(hex.uppercased())",
    kind: .notion, key: "notion:\(hex)", title: "Notion: Q4 Plan"),
  AcceptedLink(
    name: "notion site whose name contains grafana", url: "https://grafana.notion.site/Q4-Plan-\(hex)", kind: .notion,
    key: "notion:\(hex)", title: "Notion: Q4 Plan"),
]

private let refusedNotion: [RefusedLink] = [
  RefusedLink(name: "notion http", url: "http://www.notion.so/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion look-alike suffix host", url: "https://notion.so.evil.example/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion look-alike www suffix host", url: "https://www.notion.so.evil.example/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion look-alike evil-notion.so", url: "https://evil-notion.so/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion two-label site host", url: "https://a.example.notion.site/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion site without a workspace", url: "https://notion.site/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion userinfo", url: "https://www.notion.so@evil.example/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion user", url: "https://someone@www.notion.so/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion port", url: "https://www.notion.so:443/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion encoded hyphen", url: "https://www.notion.so/Q4%2DPlan-\(hex)"),
  RefusedLink(name: "notion extra segment", url: "https://www.notion.so/example/team/Q4-Plan-\(hex)"),
  RefusedLink(name: "notion missing id", url: "https://www.notion.so/example/Q4-Plan"),
  RefusedLink(name: "notion root", url: "https://www.notion.so/"),
  RefusedLink(name: "notion 31 hex digits", url: "https://www.notion.so/Q4-Plan-\(hex.dropLast())"),
  RefusedLink(name: "notion 33 hex digits", url: "https://www.notion.so/Q4-Plan-a\(hex)"),
  RefusedLink(name: "notion id with a non-hex letter", url: "https://www.notion.so/Q4-Plan-\(hex.dropLast())g"),
  RefusedLink(name: "notion slug with an underscore", url: "https://www.notion.so/Q4_Plan-\(hex)"),
  RefusedLink(name: "notion workspace with a dot", url: "https://www.notion.so/exa.mple/\(hex)"),
]

private let acceptedGoogle: [AcceptedLink] = [
  AcceptedLink(
    name: "google doc", url: "https://docs.google.com/document/d/\(gid)", kind: .google,
    key: "google:document/\(gid)", title: "Google Doc"),
  AcceptedLink(
    name: "google doc edit with query and fragment",
    url: "https://docs.google.com/document/d/\(gid)/edit?usp=sharing#heading=h.abc123", kind: .google,
    key: "google:document/\(gid)", title: "Google Doc"),
  AcceptedLink(
    name: "google sheet with gid", url: "https://docs.google.com/spreadsheets/d/\(gid)/edit?usp=sharing#gid=0",
    kind: .google, key: "google:spreadsheets/\(gid)", title: "Google Sheet"),
  AcceptedLink(
    name: "google slides view", url: "https://docs.google.com/presentation/d/\(gid)/view", kind: .google,
    key: "google:presentation/\(gid)", title: "Google Slides"),
  AcceptedLink(
    name: "google doc preview", url: "https://docs.google.com/document/d/\(gid)/preview", kind: .google,
    key: "google:document/\(gid)", title: "Google Doc"),
  AcceptedLink(
    name: "google doc with /u/0/", url: "https://docs.google.com/document/u/0/d/\(gid)/edit", kind: .google,
    key: "google:document/\(gid)", title: "Google Doc"),
  AcceptedLink(
    name: "google sheet with /u/12/", url: "https://docs.google.com/spreadsheets/u/12/d/\(gid)", kind: .google,
    key: "google:spreadsheets/\(gid)", title: "Google Sheet"),
  AcceptedLink(
    name: "google uppercase scheme and host", url: "HTTPS://DOCS.GOOGLE.COM/document/d/\(gid)/edit", kind: .google,
    key: "google:document/\(gid)", title: "Google Doc"),
  AcceptedLink(
    name: "google id of exactly 10 characters", url: "https://docs.google.com/document/d/abcDEF_-90/edit",
    kind: .google, key: "google:document/abcDEF_-90", title: "Google Doc"),
]

private let refusedGoogle: [RefusedLink] = [
  RefusedLink(name: "google http", url: "http://docs.google.com/document/d/\(gid)/edit"),
  RefusedLink(
    name: "google look-alike suffix host", url: "https://docs.google.com.evil.example/document/d/\(gid)/edit"),
  RefusedLink(name: "google look-alike evil-docs host", url: "https://evil-docs.google.com/document/d/\(gid)/edit"),
  RefusedLink(name: "google drive host", url: "https://drive.google.com/file/d/\(gid)/view"),
  RefusedLink(name: "google bare google.com", url: "https://google.com/document/d/\(gid)/edit"),
  RefusedLink(name: "google userinfo", url: "https://docs.google.com@evil.example/document/d/\(gid)/edit"),
  RefusedLink(name: "google user", url: "https://someone@docs.google.com/document/d/\(gid)/edit"),
  RefusedLink(name: "google port", url: "https://docs.google.com:443/document/d/\(gid)/edit"),
  RefusedLink(name: "google encoded slash", url: "https://docs.google.com/document/d%2F\(gid)/edit"),
  RefusedLink(name: "google encoded id character", url: "https://docs.google.com/document/d/\(gid)%41/edit"),
  RefusedLink(name: "google extra segment", url: "https://docs.google.com/document/d/\(gid)/edit/extra"),
  RefusedLink(name: "google missing id", url: "https://docs.google.com/document/d/"),
  RefusedLink(name: "google missing id and slash", url: "https://docs.google.com/document/d"),
  RefusedLink(name: "google id of 9 characters", url: "https://docs.google.com/document/d/abcDEF_-9/edit"),
  RefusedLink(name: "google id with a dot", url: "https://docs.google.com/document/d/abc.DEF_-90/edit"),
  RefusedLink(name: "google published form", url: "https://docs.google.com/document/d/e/2PACX-\(gid)/pub"),
  RefusedLink(name: "google forms type", url: "https://docs.google.com/forms/d/\(gid)/edit"),
  RefusedLink(name: "google /u/ without digits", url: "https://docs.google.com/document/u/x/d/\(gid)/edit"),
  RefusedLink(name: "google /u/ without an account", url: "https://docs.google.com/document/u/d/\(gid)/edit"),
  RefusedLink(name: "google uppercase action", url: "https://docs.google.com/document/d/\(gid)/EDIT"),
  RefusedLink(name: "google action with a digit", url: "https://docs.google.com/document/d/\(gid)/edit2"),
]

private let acceptedGrafana: [AcceptedLink] = [
  AcceptedLink(
    name: "grafana with a slug", url: "https://grafana.example.com/d/abc123/api-latency", kind: .grafana,
    key: "grafana:grafana.example.com/abc123", title: "Grafana: api latency"),
  AcceptedLink(
    name: "grafana without a slug", url: "https://grafana.example.com/d/abc123", kind: .grafana,
    key: "grafana:grafana.example.com/abc123", title: "Grafana dashboard abc123"),
  AcceptedLink(
    name: "grafana with a time range and fragment",
    url: "https://grafana.example.com/d/abc123/api-latency?orgId=1&from=now-6h&to=now#panel-2", kind: .grafana,
    key: "grafana:grafana.example.com/abc123", title: "Grafana: api latency"),
  AcceptedLink(
    name: "grafana uppercase scheme and host", url: "HTTPS://GRAFANA.EXAMPLE.COM/d/abc123/api-latency",
    kind: .grafana, key: "grafana:grafana.example.com/abc123", title: "Grafana: api latency"),
  AcceptedLink(
    name: "grafana cloud host", url: "https://example.grafana.net/d/x_Y-z9/Flag-Evaluations", kind: .grafana,
    key: "grafana:example.grafana.net/x_Y-z9", title: "Grafana: Flag Evaluations"),
  AcceptedLink(
    name: "grafana uid of 40 characters", url: "https://grafana.example.com/d/\(String(repeating: "a", count: 40))",
    kind: .grafana, key: "grafana:grafana.example.com/\(String(repeating: "a", count: 40))",
    title: "Grafana dashboard \(String(repeating: "a", count: 40))"),
  /// "The host contains grafana" accepts this host. The plan accepts that risk, because the user pasted the link.
  AcceptedLink(
    name: "grafana any host that contains grafana", url: "https://grafana.evil.example/d/abc123", kind: .grafana,
    key: "grafana:grafana.evil.example/abc123", title: "Grafana dashboard abc123"),
]

private let refusedGrafana: [RefusedLink] = [
  RefusedLink(name: "grafana http", url: "http://grafana.example.com/d/abc123/api-latency"),
  RefusedLink(name: "grafana host without grafana", url: "https://dashboards.example.com/d/abc123/api-latency"),
  RefusedLink(name: "grafana userinfo", url: "https://grafana.example.com@evil.example/d/abc123"),
  RefusedLink(name: "grafana user", url: "https://someone@grafana.example.com/d/abc123"),
  RefusedLink(name: "grafana encoded slash", url: "https://grafana.example.com/d%2Fabc123"),
  RefusedLink(name: "grafana encoded uid character", url: "https://grafana.example.com/d/abc%31"),
  RefusedLink(name: "grafana extra segment", url: "https://grafana.example.com/d/abc123/api-latency/extra"),
  RefusedLink(name: "grafana missing uid", url: "https://grafana.example.com/d/"),
  RefusedLink(name: "grafana missing uid and slash", url: "https://grafana.example.com/d"),
  RefusedLink(name: "grafana uid with a dot", url: "https://grafana.example.com/d/abc.123"),
  RefusedLink(
    name: "grafana uid of 41 characters", url: "https://grafana.example.com/d/\(String(repeating: "a", count: 41))"),
  RefusedLink(name: "grafana subpath deployment", url: "https://example.com/grafana/d/abc123/api-latency"),
  RefusedLink(name: "grafana subpath on a grafana host", url: "https://grafana.example.com/grafana/d/abc123"),
  RefusedLink(name: "grafana explore page", url: "https://grafana.example.com/explore?left=abc"),
  RefusedLink(name: "grafana slug with an underscore", url: "https://grafana.example.com/d/abc123/api_latency"),
]

private let refusedOther: [RefusedLink] = [
  RefusedLink(name: "a GitHub pull request", url: LinkFixtures.githubPR),
  RefusedLink(name: "a GitHub issue", url: "https://github.com/example/widgets/issues/7"),
  RefusedLink(name: "a claude.ai artifact", url: artifactShortURL),
  RefusedLink(name: "any other page", url: "https://example.com/doc"),
  RefusedLink(name: "empty", url: ""),
  RefusedLink(name: "not a URL", url: "not a url"),
  RefusedLink(name: "javascript", url: "javascript:alert(1)"),
  RefusedLink(name: "file", url: "file:///archives/\(ch)/\(rootP)"),
]

/// `LinkTarget.parse` accepts a URL only when its scheme, host, and whole path have the shape of one kind, and it
/// builds the key, title, channel, and thread only from the parts it checked.
@Suite struct LinkTargetTests {
  static let accepted = acceptedSlack + acceptedLinear + acceptedNotion + acceptedGoogle + acceptedGrafana
  static let refused = refusedSlack + refusedLinear + refusedNotion + refusedGoogle + refusedGrafana + refusedOther

  @Test(arguments: accepted) func anAcceptedLinkHasItsKind(_ row: AcceptedLink) throws {
    let target = try #require(LinkTarget.parse(row.url))

    #expect(target.kind == row.kind)
  }

  @Test(arguments: accepted) func anAcceptedLinkHasItsKey(_ row: AcceptedLink) throws {
    let target = try #require(LinkTarget.parse(row.url))

    #expect(target.key == row.key)
  }

  @Test(arguments: accepted) func anAcceptedLinkHasItsTitle(_ row: AcceptedLink) throws {
    let target = try #require(LinkTarget.parse(row.url))

    #expect(target.title == row.title)
  }

  /// Only a Slack link has a channel, a thread, and a message ts.
  @Test(arguments: accepted) func anAcceptedLinkHasItsChannelThreadAndMessageTs(_ row: AcceptedLink) throws {
    let target = try #require(LinkTarget.parse(row.url))

    #expect(target.channel == row.channel)
    #expect(target.thread == row.thread)
    #expect(target.messageTs == row.messageTs)
  }

  @Test(arguments: refused) func aRefusedLinkHasNoTarget(_ row: RefusedLink) {
    #expect(LinkTarget.parse(row.url) == nil)
  }

  // MARK: Ports

  /// Grafana is the only kind that takes a port. The key keeps the port, because two ports can be two servers.
  @Test func aGrafanaLinkWithAPortIsAccepted() throws {
    let target = try #require(LinkTarget.parse("https://grafana.example.com:3000/d/abc123/api-latency"))

    #expect(target.kind == .grafana)
    #expect(target.key == "grafana:grafana.example.com:3000/abc123")
    #expect(target.title == "Grafana: api latency")
  }

  @Test func grafanaLinksOnTwoPortsHaveDifferentKeys() throws {
    let first = try #require(LinkTarget.parse("https://grafana.example.com:3000/d/abc123"))
    let second = try #require(LinkTarget.parse("https://grafana.example.com:4000/d/abc123"))

    #expect(first.key != second.key)
  }

  // MARK: Titles

  @Test func aTitleFromALongSlugIsCutToTheTitleLimit() throws {
    let slug = String(repeating: "a", count: ExternalLink.titleLimit + 50)
    let target = try #require(LinkTarget.parse("https://grafana.example.com/d/abc123/\(slug)"))

    #expect(target.title.count == ExternalLink.titleLimit)
    #expect(target.title.hasPrefix("Grafana: aaa"))
    #expect(target.title.hasSuffix("…"))
  }

  // MARK: Length

  /// A link of each kind padded in its fragment, which no parser reads, so only the length decides.
  static let paddable = [
    LinkFixtures.slackRoot, LinkFixtures.linear, LinkFixtures.notion,
    "https://docs.google.com/document/d/\(LinkFixtures.googleId)/edit", "https://grafana.example.com/d/abc123",
  ]

  static func padded(_ url: String, to count: Int) -> String {
    let base = url + "#"
    return base + String(repeating: "a", count: count - base.count)
  }

  @Test(arguments: paddable) func aLinkOfExactlyTheURLLimitIsAccepted(_ url: String) throws {
    let long = Self.padded(url, to: ExternalLink.urlLimit)

    #expect(long.count == ExternalLink.urlLimit)
    #expect(LinkTarget.parse(long) != nil)
  }

  @Test(arguments: paddable) func aLinkOneOverTheURLLimitIsRefused(_ url: String) {
    let long = Self.padded(url, to: ExternalLink.urlLimit + 1)

    #expect(LinkTarget.parse(long) == nil)
  }

  // MARK: Parity

  /// Two links to one page share a key, so the session list holds one entry for them.
  @Test(arguments: [
    (LinkFixtures.slackRoot, LinkFixtures.slackReply),
    (LinkFixtures.slackRoot, "\(LinkFixtures.slackRoot)?cid=\(ch)"),
    (LinkFixtures.slackRoot, "HTTPS://EXAMPLE.SLACK.COM/archives/\(ch)/\(rootP)"),
    (
      "https://example.slack.com/archives/\(ch)/\(replyP)?thread_ts=\(rootTs)",
      "https://example.slack.com/archives/\(ch)/p1794965300000900?thread_ts=\(rootTs)"
    ),
    ("https://www.notion.so/\(hex)", "https://notion.so/Q4-Plan-\(hex)"),
    ("https://www.notion.so/\(hex)", "https://example.notion.site/Q4-Plan-\(hex)?pvs=4"),
    ("https://www.notion.so/\(hex)", "https://www.notion.so/other/Renamed-Page-\(hex.uppercased())"),
    ("https://linear.app/example/issue/ENG-123", "https://linear.app/example/issue/ENG-123/fix-the-flag-cache"),
    ("https://linear.app/example/issue/ENG-123", "https://linear.app/Example/issue/eng-123"),
    ("https://docs.google.com/document/d/\(gid)/edit", "https://docs.google.com/document/u/0/d/\(gid)/view"),
    ("https://docs.google.com/document/d/\(gid)", "https://docs.google.com/document/d/\(gid)/edit?usp=sharing#gid=0"),
    ("https://grafana.example.com/d/abc123", "https://grafana.example.com/d/abc123/api-latency?from=now-6h&to=now"),
    ("https://grafana.example.com/d/abc123", "https://GRAFANA.example.com/d/abc123/renamed"),
  ])
  func twoLinksToOnePageShareAKey(_ a: String, _ b: String) throws {
    let first = try #require(LinkTarget.parse(a))
    let second = try #require(LinkTarget.parse(b))

    #expect(first.key == second.key)
  }

  @Test(arguments: [
    (LinkFixtures.slackRoot, "https://example.slack.com/archives/C0EXAMPLE02/\(rootP)"),
    (LinkFixtures.slackRoot, "https://example.slack.com/archives/\(ch)/\(replyP)"),
    (LinkFixtures.slackRoot, "https://other.slack.com/archives/\(ch)/\(rootP)"),
    ("https://linear.app/example/issue/ENG-123", "https://linear.app/other/issue/ENG-123"),
    ("https://linear.app/example/issue/ENG-123", "https://linear.app/example/issue/ENG-124"),
    ("https://www.notion.so/\(hex)", "https://www.notion.so/\(hex.dropLast())e"),
    ("https://docs.google.com/document/d/\(gid)", "https://docs.google.com/spreadsheets/d/\(gid)"),
    ("https://grafana.example.com/d/abc123", "https://grafana.other.example/d/abc123"),
    ("https://grafana.example.com/d/abc123", "https://grafana.example.com/d/abc124"),
  ])
  func linksToTwoPagesHaveTwoKeys(_ a: String, _ b: String) throws {
    let first = try #require(LinkTarget.parse(a))
    let second = try #require(LinkTarget.parse(b))

    #expect(first.key != second.key)
  }

  /// A key belongs to one kind, so links of two kinds can never share one.
  @Test func everyAcceptedKeyStartsWithItsKind() throws {
    for row in Self.accepted {
      let target = try #require(LinkTarget.parse(row.url), "\(row.name)")
      #expect(target.key.hasPrefix("\(target.kind.rawValue):"), "\(row.name)")
    }
  }
}

/// The kinds and authors that a link carries.
@Suite struct LinkKindAndAuthorTests {
  @Test func theKindsAreTheFiveKnownKindsAndWeb() {
    #expect(LinkKind.allCases.map(\.rawValue) == ["slack", "linear", "notion", "google", "grafana", "web"])
  }

  @Test(arguments: [(Author.you, LinkAuthor.you), (.claude, .claude)])
  func aLinkAuthorFromAnAuthorKeepsIt(_ author: Author, _ expected: LinkAuthor) {
    #expect(LinkAuthor(author) == expected)
  }

  @Test func theLinkAuthorsAreFoundYouAndClaude() throws {
    let decoded = try ["found", "you", "claude"].map { try JSONCoding.decode(LinkAuthor.self, from: "\"\($0)\"") }

    #expect(decoded == [.found, .you, .claude])
  }

  /// `found` is only for links that sbd derives. A request that takes `by` still refuses it.
  @Test func anAuthorRefusesFound() {
    #expect(throws: (any Error).self) { try Author(parsing: "found") }
  }
}
