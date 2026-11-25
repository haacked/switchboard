import SwiftUI
import SwitchboardCore

/// The toolbar control that names the org filter and the group filter. Its
/// popover lists each GitHub org that has sessions and each group, with a
/// checkbox and a count. It always shows, so a filter is never on without a
/// visible sign.
struct SessionFilterMenu: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let orgEntries = model.orgEntries
    let groupEntries = model.groupEntries
    let on = !model.filter.isAll
    Button {
      model.showingFilter.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        Text(model.filter.label(orgEntries: orgEntries, groupEntries: groupEntries))
          .lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .foregroundStyle(on ? Color.accentColor : .primary)
    }
    .help(AppShortcut.filterSessions.help("Show sessions from some GitHub orgs or groups only"))
    .accessibilityIdentifier("session-filter")
    .popover(isPresented: $model.showingFilter, arrowEdge: .bottom) {
      SessionFilterList(orgEntries: orgEntries, groupEntries: groupEntries)
    }
  }
}

/// The popover of the filter: an Orgs section and a Groups section.
private struct SessionFilterList: View {
  @EnvironmentObject var model: BoardModel
  var orgEntries: [FilterEntry]
  var groupEntries: [FilterEntry]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        FilterSection(
          heading: "Orgs", filter: $model.orgFilter, entries: orgEntries, empty: "No sessions in a GitHub org yet."
        ) { entry in
          entry.key == OrgFilter.localKey ? "Sessions with no GitHub remote" : "Sessions in \(entry.title) repos"
        }
        Divider().padding(.vertical, 4)
        FilterSection(heading: "Groups", filter: $model.groupFilter, entries: groupEntries, empty: "No groups yet.") {
          entry in
          entry.key == GroupFilter.ungroupedKey ? "Sessions in no group" : "Sessions in \(entry.title)"
        }
        Divider().padding(.vertical, 4)
        Text("The filter only hides sessions. They keep running.")
          .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
      }
      .padding(8)
    }
    .frame(width: 280)
    .frame(maxHeight: 520)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// One dimension of the filter: its All row, then a row per entry.
private struct FilterSection<Filter: KeyFilter>: View {
  var heading: String
  @Binding var filter: Filter
  var entries: [FilterEntry]
  var empty: String
  var help: (FilterEntry) -> String

  var body: some View {
    Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 8).padding(.vertical, 2)
    row(
      title: Filter.allTitle, count: entries.reduce(0) { $0 + $1.count }, needsYou: 0, checked: filter.isAll,
      help: "Don't filter by \(heading.lowercased())"
    ) { filter = Filter(keys: [String]()) }
    if entries.isEmpty {
      Text(empty).font(.callout).foregroundStyle(.secondary).padding(8)
    }
    ForEach(entries) { entry in
      row(
        title: entry.title, count: entry.count, needsYou: entry.needsYou, checked: filter.keys.contains(entry.key),
        help: help(entry)
      ) { filter.toggle(entry.key) }
    }
  }

  private func row(
    title: String, count: Int, needsYou: Int, checked: Bool, help: String, action: @escaping () -> Void
  ) -> some View {
    Toggle(isOn: Binding(get: { checked }, set: { _ in action() })) {
      HStack(spacing: 8) {
        Text(title).lineLimit(1)
        Spacer()
        if needsYou > 0 {
          Text("\(needsYou) need\(needsYou == 1 ? "s" : "") you").font(.caption)
            .foregroundStyle(AttentionState.needsYou.color)
        }
        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .help(help)
  }
}

extension SessionFilter.Scope {
  /// "the org filter", "the group filter", or "the filters".
  var filterName: String {
    switch self {
    case .orgs: "the org filter"
    case .groups: "the group filter"
    case .both: "the filters"
    }
  }

  /// What the filter selects, as in "in these orgs": "orgs", "groups", or "orgs and groups".
  var selection: String {
    switch self {
    case .orgs: "orgs"
    case .groups: "groups"
    case .both: "orgs and groups"
    }
  }
}

/// The bar under the sidebar while a filter is on. It says how many sessions
/// the filter hides, and how many of those need the user.
struct FilterBar: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if let scope = model.filter.scope {
      let needYou = model.hiddenNeedingYou
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(Self.text(hidden: model.hiddenCount, scope: scope))
          if needYou > 0 {
            Text("\(needYou) of them need\(needYou == 1 ? "s" : "") you")
              .foregroundStyle(AttentionState.needsYou.color)
          }
        }
        .font(.caption)
        Spacer(minLength: 4)
        Button("Show All") { model.showAll() }
          .buttonStyle(.borderless)
          .font(.caption)
          .accessibilityIdentifier("filter-show-all")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.bar)
    }
  }

  /// "3 sessions hidden by the org filter".
  static func text(hidden: Int, scope: SessionFilter.Scope) -> String {
    "\(hidden) session\(hidden == 1 ? "" : "s") hidden by \(scope.filterName)"
  }
}

/// What the Board and the sidebar show when the filters hide every work session.
struct FilterHidesAll: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if let scope = model.filter.scope {
      ContentUnavailableView {
        Label(Self.title(scope: scope), systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text("The filter only hides sessions. They keep running.")
      } actions: {
        Button("Show All") { model.showAll() }
      }
    }
  }

  /// "The group filter hides every session".
  static func title(scope: SessionFilter.Scope) -> String {
    Triage.capitalized(scope.filterName) + (scope == .both ? " hide" : " hides") + " every session"
  }
}
