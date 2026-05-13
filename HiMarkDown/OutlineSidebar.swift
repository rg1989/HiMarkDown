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
            let groups = groupHeadings(document.headings)
            if groups.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                List {
                    ForEach(groups, id: \.root.index) { group in
                        let key = outlineKey(group.root)
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
                                    Text(child.title)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(outlineRowBackground(isActive: document.outlineSyncedHeadingIndex == child.index))
                            }
                        } label: {
                            Button {
                                onSelectHeading(group.root.index)
                            } label: {
                                Text(group.root.title)
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
                    }
                }
                .listStyle(.sidebar)
                .tint(HiAppearance.brand)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: document.fileURL) { _ in
            DispatchQueue.main.async { expandAllRoots() }
        }
        .onAppear {
            DispatchQueue.main.async { expandAllRoots() }
        }
    }

    private func outlineKey(_ h: HeadingEntry) -> String {
        "\(h.index)"
    }

    /// Root row is active when the synced heading is the root itself, or when
    /// the synced heading is a nested child but this disclosure is collapsed
    /// (children are hidden, so the parent should show “you are here”).
    private func isRootOutlineRowActive(group: HeadingGroup, disclosureKey: String) -> Bool {
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

    private func expandAllRoots() {
        let groups = groupHeadings(document.headings)
        for g in groups {
            document.outlineExpanded.insert(outlineKey(g.root))
        }
    }

    private struct HeadingGroup {
        let root: HeadingEntry
        let children: [HeadingEntry]
    }

    private func groupHeadings(_ flat: [HeadingEntry]) -> [HeadingGroup] {
        guard !flat.isEmpty else { return [] }
        let rootLevel = flat.first?.level ?? 1
        var groups: [HeadingGroup] = []
        var i = 0
        while i < flat.count {
            let h = flat[i]
            if h.level == rootLevel {
                var children: [HeadingEntry] = []
                i += 1
                while i < flat.count, flat[i].level > rootLevel {
                    children.append(flat[i])
                    i += 1
                }
                groups.append(HeadingGroup(root: h, children: children))
            } else {
                groups.append(HeadingGroup(root: h, children: []))
                i += 1
            }
        }
        return groups
    }
}
