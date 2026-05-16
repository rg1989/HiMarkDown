import SwiftUI

struct OutlineSidebar: View {
    @EnvironmentObject private var document: DocumentModel

    var onSelectHeading: (Int) -> Void

    private var tree: [OutlineNode] {
        HeadingParser.outlineTree(document.headings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.headline)
                .foregroundStyle(HiAppearance.brand)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            if tree.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                ScrollViewReader { scrollProxy in
                    List {
                        ForEach(tree) { node in
                            OutlineNodeRow(node: node, depth: 0, onSelectHeading: onSelectHeading)
                        }
                    }
                    .listStyle(.sidebar)
                    .tint(HiAppearance.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: document.outlineSyncedHeadingIndex) { _ in
                        autoExpandToActive()
                        // outlineExpanded change triggers its own scrollToSynced;
                        // call directly too in case expansion didn't change.
                        scrollToSynced(proxy: scrollProxy)
                    }
                    .onChange(of: document.outlineExpanded) { _ in
                        scrollToSynced(proxy: scrollProxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: document.fileURL) { _ in
            Task { @MainActor in autoExpandToActive() }
        }
        .onAppear {
            Task { @MainActor in autoExpandToActive() }
        }
    }

    /// Expand only the ancestors of the active heading (accordion: everything
    /// else collapses). Sets outlineExpanded to exactly the ancestor key set.
    private func autoExpandToActive() {
        guard let synced = document.outlineSyncedHeadingIndex,
              let keys = findAncestorKeys(of: synced, in: tree) else { return }
        document.outlineExpanded = keys
    }

    /// Returns the set of node keys that are ancestors of `syncedIndex`,
    /// or nil if `syncedIndex` is not found in `nodes`.
    private func findAncestorKeys(of syncedIndex: Int, in nodes: [OutlineNode]) -> Set<String>? {
        for node in nodes {
            if node.entry.index == syncedIndex { return [] }
            if let childKeys = findAncestorKeys(of: syncedIndex, in: node.children) {
                var result = childKeys
                result.insert("\(node.entry.index)")
                return result
            }
        }
        return nil
    }

    private func scrollToSynced(proxy: ScrollViewProxy) {
        guard let id = scrollTarget(synced: document.outlineSyncedHeadingIndex, in: tree) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func scrollTarget(synced: Int?, in nodes: [OutlineNode]) -> Int? {
        guard let synced else { return nil }
        for node in nodes {
            if let found = scrollTarget(synced: synced, in: node) { return found }
        }
        return nil
    }

    private func scrollTarget(synced: Int, in node: OutlineNode) -> Int? {
        if node.entry.index == synced { return synced }
        let key = "\(node.entry.index)"
        let expanded = document.outlineExpanded.contains(key)
        if !expanded {
            return containsIndex(synced, in: node) ? node.entry.index : nil
        }
        for child in node.children {
            if let found = scrollTarget(synced: synced, in: child) { return found }
        }
        return nil
    }

    private func containsIndex(_ index: Int, in node: OutlineNode) -> Bool {
        if node.entry.index == index { return true }
        return node.children.contains { containsIndex(index, in: $0) }
    }
}

private struct OutlineNodeRow: View {
    let node: OutlineNode
    let depth: Int
    var onSelectHeading: (Int) -> Void

    @EnvironmentObject private var document: DocumentModel

    var body: some View {
        if node.children.isEmpty {
            leafButton
        } else {
            branchGroup
        }
    }

    private var leafButton: some View {
        Button {
            onSelectHeading(node.entry.index)
        } label: {
            Text(node.entry.title.outlineDecodedBasicEntities)
                .lineLimit(2)
                .foregroundStyle(depth == 0 ? HiAppearance.brand : Color.primary)
                .fontWeight(depth == 0 ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .id(node.entry.index)
        .listRowBackground(rowBackground)
    }

    private var branchGroup: some View {
        let key = "\(node.entry.index)"
        return DisclosureGroup(
            isExpanded: Binding(
                get: { document.outlineExpanded.contains(key) },
                set: { expanded in
                    DispatchQueue.main.async {
                        if expanded { document.outlineExpanded.insert(key) }
                        else { document.outlineExpanded.remove(key) }
                    }
                }
            )
        ) {
            ForEach(node.children) { child in
                OutlineNodeRow(node: child, depth: depth + 1, onSelectHeading: onSelectHeading)
            }
        } label: {
            Button {
                onSelectHeading(node.entry.index)
            } label: {
                Text(node.entry.title.outlineDecodedBasicEntities)
                    .lineLimit(2)
                    .foregroundStyle(depth == 0 ? HiAppearance.brand : Color.primary)
                    .fontWeight(depth == 0 ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .listRowBackground(rowBackground)
        }
        .id(node.entry.index)
    }

    // A node is active if it IS the synced heading or any ancestor of it —
    // so both the parent section and the specific child are highlighted.
    private var isActive: Bool {
        guard let synced = document.outlineSyncedHeadingIndex else { return false }
        return containsIndex(synced, in: node)
    }

    private func containsIndex(_ index: Int, in node: OutlineNode) -> Bool {
        if node.entry.index == index { return true }
        return node.children.contains { containsIndex(index, in: $0) }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            HiAppearance.brand.opacity(0.18)
        } else {
            Color.clear
        }
    }
}

private extension String {
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
