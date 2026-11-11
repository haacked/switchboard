import SwiftUI
import SwitchboardCore

/// The toolbar control that names the org filter. Its popover lists each
/// GitHub org that has sessions, with a checkbox and a count. It always
/// shows, so a filter is never on without a visible sign.
struct OrgFilterMenu: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    let entries = model.orgEntries
    let on = !model.orgFilter.isAll
    Button {
      model.showingOrgFilter.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        Text(model.orgFilter.label(entries)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
        Image(systemName: "chevron.down").imageScale(.small)
      }
      .foregroundStyle(on ? Color.accentColor : .primary)
    }
    .help("Show sessions from some GitHub orgs only (⇧⌘O)")
    .accessibilityIdentifier("org-filter")
    .popover(isPresented: $model.showingOrgFilter, arrowEdge: .bottom) {
      OrgFilterList(entries: entries)
    }
  }
}

/// The popover of the org filter.
private struct OrgFilterList: View {
  @EnvironmentObject var model: BoardModel
  var entries: [OrgFilter.Entry]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      row(
        title: "All Orgs", count: entries.reduce(0) { $0 + $1.count }, needsYou: 0,
        checked: model.orgFilter.isAll, help: "Show every session"
      ) { model.orgFilter = OrgFilter() }
      Divider().padding(.vertical, 4)
      if entries.isEmpty {
        Text("No sessions in a GitHub org yet.").font(.callout).foregroundStyle(.secondary).padding(8)
      }
      ForEach(entries) { entry in
        row(
          title: entry.title, count: entry.count, needsYou: entry.needsYou,
          checked: model.orgFilter.keys.contains(entry.key),
          help: entry.key == OrgFilter.localKey ? "Sessions with no GitHub remote" : "Sessions in \(entry.title) repos"
        ) { model.orgFilter.toggle(entry.key) }
      }
      Divider().padding(.vertical, 4)
      Text("The filter only hides sessions. They keep running.")
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
    }
    .padding(8)
    .frame(width: 260)
  }

  private func row(
    title: String, count: Int, needsYou: Int, checked: Bool, help: String, action: @escaping () -> Void
  ) -> some View {
    Toggle(isOn: Binding(get: { checked }, set: { _ in action() })) {
      HStack(spacing: 8) {
        Text(title)
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

/// The bar under the sidebar while a filter is on. It says how many sessions
/// the filter hides, and how many of those need the user.
struct OrgFilterBar: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if !model.orgFilter.isAll {
      let hidden = model.hiddenCount
      let needYou = model.hiddenNeedingYou
      HStack(spacing: 6) {
        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text("\(hidden) session\(hidden == 1 ? "" : "s") hidden by the org filter")
          if needYou > 0 {
            Text("\(needYou) of them need\(needYou == 1 ? "s" : "") you")
              .foregroundStyle(AttentionState.needsYou.color)
          }
        }
        .font(.caption)
        Spacer(minLength: 4)
        Button("Show All") { model.orgFilter = OrgFilter() }
          .buttonStyle(.borderless)
          .font(.caption)
          .accessibilityIdentifier("org-filter-show-all")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.bar)
    }
  }
}
