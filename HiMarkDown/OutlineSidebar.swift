import SwiftUI

struct OutlineSidebar: View {
    @EnvironmentObject private var document: DocumentModel

    var onSelectHeading: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.headline)
                .foregroundStyle(HiAppearance.brand)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            let groups = HeadingParser.outlineGroups(document.headings)
            if groups.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                ScrollViewReader { scrollProxy in
                    List {
                        ForEach(groups, id: \.root.index) { group in
                            let key = outlineKey(group.root)
                            if group.children.isEmpty {
                                Button {
                                    onSelectHeading(group.root.index)
                                } label: {
                                    Text(group.root.title.outlineDecodedBasicEntities)
                                        .fontWeight(.semibold)
                                        .lineLimit(2)
                                        .foregroundStyle(HiAppearance.brand)
                                }
                                .buttonStyle(.plain)
                                .id(group.root.index)
                                .listRowBackground(
                                    outlineRowBackground(
                                        isActive: isRootOutlineRowActive(group: group, disclosureKey: key)
                                    )
                                )
                            } else {
                                DisclosureGroup(
                                    isExpanded: Binding(
                                        get: { document.outlineExpanded.contains(key) },
                                        set: { expanded in
                                            DispatchQueue.main.async {
                                                if expanded {
                                                    document.outlineExpanded.insert(key)
                                                } else {
                                                    document.outlineExpanded.remove(key)
                                                }
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(group.children, id: \.index) { child in
                                        Button {
                                            onSelectHeading(child.index)
                                        } label: {
                                            Text(child.title.outlineDecodedBasicEntities)
                                                .lineLimit(2)
                                                .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)
                                        .id(child.index)
                                        .listRowBackground(
                                            outlineRowBackground(isActive: document.outlineSyncedHeadingIndex == child.index)
                                        )
                                    }
                                } label: {
                                    Button {
                                        onSelectHeading(group.root.index)
                                    } label: {
                                        Text(group.root.title.outlineDecodedBasicEntities)
                                            .fontWeight(.semibold)
                                            .lineLimit(2)
                                            .foregroundStyle(HiAppearance.brand)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(
                                        outlineRowBackground(
                                            isActive: isRootOutlineRowActive(group: group, disclosureKey: key)
                                        )
                                    )
                                }
                                .id(group.root.index)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .tint(HiAppearance.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: document.outlineSyncedHeadingIndex) { _ in
                        scrollOutlineToSyncedSelection(
                            proxy: scrollProxy,
                            groups: HeadingParser.outlineGroups(document.headings)
                        )
                    }
                    .onChange(of: document.outlineExpanded) { _ in
                        scrollOutlineToSyncedSelection(
                            proxy: scrollProxy,
                            groups: HeadingParser.outlineGroups(document.headings)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: document.fileURL) { _ in
            Task { @MainActor in
                expandBranchGroupsOnly()
            }
        }
        .onAppear {
            Task { @MainActor in
                expandBranchGroupsOnly()
            }
        }
    }

    /// Which list row id `ScrollViewReader` should center on: child row when
    /// expanded, otherwise the parent row (the only visible target when folded).
    private func outlineScrollTargetID(synced: Int?, groups: [HeadingOutlineGroup]) -> Int? {
        guard let synced else { return nil }
        for g in groups {
            if synced == g.root.index {
                return g.root.index
            }
            if g.children.contains(where: { $0.index == synced }) {
                let key = outlineKey(g.root)
                let expanded = document.outlineExpanded.contains(key)
                return expanded ? synced : g.root.index
            }
        }
        return nil
    }

    private func scrollOutlineToSyncedSelection(
        proxy: ScrollViewProxy,
        groups: [HeadingOutlineGroup]
    ) {
        guard let id = outlineScrollTargetID(synced: document.outlineSyncedHeadingIndex, groups: groups) else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func outlineKey(_ h: HeadingEntry) -> String {
        "\(h.index)"
    }

    /// Root row is active when the synced heading is the root itself, or when
    /// the synced heading is a nested child but this disclosure is collapsed
    /// (children are hidden, so the parent should show “you are here”).
    private func isRootOutlineRowActive(group: HeadingOutlineGroup, disclosureKey: String) -> Bool {
        guard let synced = document.outlineSyncedHeadingIndex else { return false }
        if synced == group.root.index { return true }
        guard group.children.contains(where: { $0.index == synced }) else { return false }
        let expanded = document.outlineExpanded.contains(disclosureKey)
        return !expanded
    }

    @ViewBuilder
    private func outlineRowBackground(isActive: Bool) -> some View {
        if isActive {
            HiAppearance.brand.opacity(0.18)
        } else {
            Color.clear
        }
    }

    /// Only headings that actually have nested outline rows get a disclosure;
    /// expand those by default on open so the tree matches the document.
    private func expandBranchGroupsOnly() {
        for g in HeadingParser.outlineGroups(document.headings) where !g.children.isEmpty {
            document.outlineExpanded.insert(outlineKey(g.root))
        }
    }
}

private extension String {
    /// TipTap / markdown may leave XML entities in heading text; decode the
    /// common ones for readable outline labels.
    var outlineDecodedBasicEntities: String {
        self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
