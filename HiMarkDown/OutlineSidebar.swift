import SwiftUI

struct OutlineSidebar: View {
    @EnvironmentObject private var document: DocumentModel

    var onSelectHeading: (Int) -> Void

    @State private var searchText = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    private var tree: [OutlineNode] {
        HeadingParser.outlineTree(document.headings)
    }

    private var filteredHeadings: [HeadingEntry] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return document.headings.filter {
            $0.title.outlineDecodedBasicEntities
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            outlineHeader
            gradientDivider
            if showSearch {
                searchBar
                Rectangle()
                    .fill(HiAppearance.brand.opacity(0.12))
                    .frame(height: 1)
            }
            if showSearch && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResultsView
            } else if tree.isEmpty {
                emptyState
            } else {
                outlineScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: showSearch)
        .onChange(of: document.fileURL) { _ in
            Task { @MainActor in autoExpandToActive() }
        }
        .onAppear {
            Task { @MainActor in autoExpandToActive() }
        }
        .onChange(of: showSearch) { isShowing in
            if isShowing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    searchFocused = true
                }
            } else {
                searchText = ""
            }
        }
    }

    private var outlineHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HiAppearance.brand)
            Text("Outline")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [HiAppearance.brand, HiAppearance.brandSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch.toggle()
                }
            } label: {
                Image(systemName: showSearch ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showSearch ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(HiAppearance.brand.opacity(0.65)))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showSearch ? "Close search" : "Search headings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var gradientDivider: some View {
        LinearGradient(
            colors: [HiAppearance.brand.opacity(0.55), HiAppearance.brandSecondary.opacity(0.3), Color.clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HiAppearance.brand.opacity(0.6))
            TextField("Search headings…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(HiAppearance.brand.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(HiAppearance.brand.opacity(0.2), lineWidth: 0.75)
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var searchResultsView: some View {
        let results = filteredHeadings
        return ScrollView(.vertical, showsIndicators: false) {
            if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .thin))
                        .foregroundStyle(HiAppearance.brand.opacity(0.3))
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { heading in
                        SearchResultRow(heading: heading, onSelect: {
                            onSelectHeading(heading.index)
                        })
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 5)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 26, weight: .thin))
                .foregroundStyle(HiAppearance.brand.opacity(0.3))
            Text("No headings")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 48)
    }

    private var outlineScrollView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tree) { node in
                        OutlineNodeRow(node: node, depth: 0, onSelectHeading: onSelectHeading)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 5)
            }
            .onChange(of: document.outlineSyncedHeadingIndex) { _ in
                autoExpandToActive()
                scrollToSynced(proxy: scrollProxy)
            }
            .onChange(of: document.outlineExpanded) { _ in
                scrollToSynced(proxy: scrollProxy)
            }
        }
    }

    private func autoExpandToActive() {
        guard let synced = document.outlineSyncedHeadingIndex,
              let keys = findAncestorKeys(of: synced, in: tree) else { return }
        document.outlineExpanded = keys
    }

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
    @State private var isHovered = false

    private var key: String { "\(node.entry.index)" }
    private var isExpanded: Bool { document.outlineExpanded.contains(key) }
    private var hasChildren: Bool { !node.children.isEmpty }

    private var isActive: Bool {
        guard let synced = document.outlineSyncedHeadingIndex else { return false }
        return containsIndex(synced, in: node)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if hasChildren && isExpanded {
                childRows
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Depth indentation with guide line
            if depth > 0 {
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(HiAppearance.brand.opacity(0.2))
                        .frame(width: 1)
                        .padding(.leading, 10)
                }
                .frame(width: CGFloat(depth) * 14)
            }

            // Leading padding before text
            Color.clear.frame(width: 4)

            // Navigate on tap
            Button {
                onSelectHeading(node.entry.index)
            } label: {
                Text(node.entry.title.outlineDecodedBasicEntities)
                    .lineLimit(2)
                    .font(rowFont)
                    .foregroundStyle(rowTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)

            // Chevron — expand/collapse only (visually separated from text)
            if hasChildren {
                Button {
                    let k = key
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            if document.outlineExpanded.contains(k) {
                                document.outlineExpanded.remove(k)
                            } else {
                                document.outlineExpanded.insert(k)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(HiAppearance.brand.opacity(isExpanded ? 0.95 : 0.45))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.22), value: isExpanded)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 26)
            }
        }
        .background(rowBackground)
        .id(node.entry.index)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var childRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(node.children) { child in
                OutlineNodeRow(node: child, depth: depth + 1, onSelectHeading: onSelectHeading)
            }
        }
    }

    private var rowFont: Font {
        switch depth {
        case 0: return .system(size: 12, weight: .semibold)
        case 1: return .system(size: 12, weight: .regular)
        default: return .system(size: 11.5, weight: .regular)
        }
    }

    private var rowTextColor: Color {
        if isActive { return HiAppearance.brand }
        switch depth {
        case 0: return Color.primary
        default: return Color.primary.opacity(0.72)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(HiAppearance.brand.opacity(0.14))
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [HiAppearance.brand, HiAppearance.brandSecondary.opacity(0.75)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.leading, 1)
            }
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(HiAppearance.brand.opacity(0.07))
        } else {
            Color.clear
        }
    }

    private func containsIndex(_ index: Int, in node: OutlineNode) -> Bool {
        if node.entry.index == index { return true }
        return node.children.contains { containsIndex(index, in: $0) }
    }
}

private struct SearchResultRow: View {
    let heading: HeadingEntry
    var onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text("H\(heading.level)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(levelColor))
                Text(heading.title.outlineDecodedBasicEntities)
                    .font(.system(size: 12, weight: heading.level == 1 ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(heading.level == 1 ? 1.0 : 0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 6)
                    .fill(HiAppearance.brand.opacity(0.07))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    private var levelColor: Color {
        switch heading.level {
        case 1: return HiAppearance.brand
        case 2: return HiAppearance.brand.opacity(0.7)
        case 3: return HiAppearance.brandSecondary.opacity(0.8)
        default: return Color.secondary.opacity(0.55)
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
