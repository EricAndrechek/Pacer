import SwiftUI
import SwiftData
import Charts
import PacerCore
import PacerUI

/// Scoped drill-down for one collection — the "scope, don't co-rank"
/// answer to the leaderboard-dwarfing problem. The collection's total is
/// a header spotlight (never a bar competing with projects); its member
/// projects are ranked *within* it; sub-collections drill one level
/// deeper on the same modal stack.
///
/// All-time scope (a collection's full history), like a project
/// drill-down. Reads `ProjectDailyAggregate` and resolves membership at
/// read time via `CollectionResolver` — no stored rollup.
struct CollectionDetailView: View {
    let collectionID: String

    @Query private var collections: [ProjectCollection]
    @Query private var aggregates: [ProjectDailyAggregate]
    @Environment(\.pacerModalPush) private var push

    var body: some View {
        if let collection = collections.first(where: { $0.id == collectionID }) {
            resolved(collection)
        } else {
            PacerModalContent(title: "Collection") {
                Text("This collection no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resolved(_ collection: ProjectCollection) -> some View {
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let perPath = CollectionUsageRollup.perPathTotals(from: aggregates)
        let members = CollectionResolver.resolve(
            collectionID, collections: byID, knownPaths: Array(perPath.keys)
        )
        let totals = CollectionUsageRollup.totals(for: members, perPath: perPath)
        let ranked = members
            .map { (path: $0, totals: perPath[$0] ?? .zero) }
            .sorted { $0.totals.cost > $1.totals.cost }
        let hue = pacerCollectionColor(seed: collection.colorSeed, hex: collection.colorHex)

        PacerModalContent(
            title: collection.name,
            subtitle: subtitle(memberCount: members.count, collection: collection),
            idealWidth: 680,
            idealHeight: 640
        ) {
            spotlight(totals: totals, memberCount: members.count, hue: hue)
            if !ranked.isEmpty {
                dailyTrend(members: members, hue: hue)
            }
            membersCard(ranked: ranked, hue: hue)
            if !collection.childCollectionIDs.isEmpty {
                subCollectionsCard(collection: collection, byID: byID, perPath: perPath)
            }
            overlapNote
        }
    }

    private func subtitle(memberCount: Int, collection: ProjectCollection) -> String {
        var bits = ["\(memberCount) project\(memberCount == 1 ? "" : "s")"]
        if !collection.rules.isEmpty { bits.append("rule") }
        if !collection.childCollectionIDs.isEmpty { bits.append("\(collection.childCollectionIDs.count) sub") }
        return bits.joined(separator: " · ")
    }

    // MARK: Spotlight

    private func spotlight(totals: ProjectUsageTotals, memberCount: Int, hue: Color) -> some View {
        PacerCard {
            HStack(alignment: .top, spacing: 24) {
                MetricTile(
                    value: pacerCost(totals.cost),
                    label: "Total cost",
                    size: .hero,
                    tooltip: pacerCostExact(totals.cost)
                )
                MetricTile(value: pacerTokens(totals.totalTokens), label: "Tokens", size: .regular)
                MetricTile(value: "\(totals.sessionCount)", label: "Sessions", size: .regular)
                MetricTile(value: "\(memberCount)", label: "Projects", size: .regular)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Daily trend (one-encoding bars)

    private func dailyTrend(members: Set<String>, hue: Color) -> some View {
        // Cost per day across all members, last 45 active days.
        var byDate: [String: Double] = [:]
        for r in aggregates where members.contains(r.projectPath) {
            byDate[r.date, default: 0] += r.totalCostUSD
        }
        let series = byDate.sorted { $0.key < $1.key }.suffix(45)
        return PacerCard("Daily cost") {
            if series.isEmpty {
                Text("No activity yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(series, id: \.key) { day in
                    BarMark(
                        x: .value("Day", day.key),
                        y: .value("Cost", day.value)
                    )
                    .foregroundStyle(hue)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
        }
    }

    // MARK: Members ranked within

    private func membersCard(ranked: [(path: String, totals: ProjectUsageTotals)], hue: Color) -> some View {
        let maxCost = ranked.map(\.totals.cost).max() ?? 0
        return PacerCard("Projects in this collection") {
            if ranked.isEmpty {
                Text("No member projects with activity yet. Add projects from the collections manager.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(ranked, id: \.path) { member in
                        HoverRow(action: {
                            push(.project(path: member.path, displayName: pacerShortPath(member.path), since: nil))
                        }) {
                            memberRow(member, maxCost: maxCost, hue: hue)
                        }
                    }
                }
            }
        }
    }

    private func memberRow(_ member: (path: String, totals: ProjectUsageTotals), maxCost: Double, hue: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(pacerShortPath(member.path))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(pacerCost(member.totals.cost))
                    .font(.callout)
                    .monospacedDigit()
                    .help(pacerCostExact(member.totals.cost))
            }
            // Normalized one-encoding bar — length encodes cost, the only
            // variable. Color is the collection's identity hue, not a
            // second dimension.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(hue.opacity(0.55))
                    .frame(width: maxCost > 0 ? geo.size.width * (member.totals.cost / maxCost) : 0, height: 4)
            }
            .frame(height: 4)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    // MARK: Sub-collections

    private func subCollectionsCard(
        collection: ProjectCollection,
        byID: [String: ProjectCollection],
        perPath: [String: ProjectUsageTotals]
    ) -> some View {
        let children: [(child: ProjectCollection, cost: Double)] = collection.childCollectionIDs.compactMap { cid in
            guard let child = byID[cid] else { return nil }
            let members = CollectionResolver.resolve(cid, collections: byID, knownPaths: Array(perPath.keys))
            return (child, CollectionUsageRollup.totals(for: members, perPath: perPath).cost)
        }
        return PacerCard("Sub-collections") {
            VStack(spacing: 0) {
                ForEach(children, id: \.child.id) { entry in
                    HoverRow(action: { push(.collection(id: entry.child.id)) }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(pacerCollectionColor(seed: entry.child.colorSeed, hex: entry.child.colorHex))
                                .frame(width: 8, height: 8)
                            Text(entry.child.name).font(.callout)
                            Spacer(minLength: 8)
                            Text(pacerCost(entry.cost)).font(.callout).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private var overlapNote: some View {
        Text("A project can belong to several collections, so collection totals overlap and don't sum to your overall usage — each is its own lens.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
