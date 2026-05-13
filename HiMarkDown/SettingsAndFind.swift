import AppKit
import SwiftUI

enum HiAppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@MainActor
final class UserSettings: ObservableObject {
    @AppStorage("defaultEditModeIsMarkdown") var defaultEditModeIsMarkdown: Bool = false

    @Published var appAppearance: HiAppAppearance {
        didSet { UserDefaults.standard.set(appAppearance.rawValue, forKey: "HiAppAppearance") }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "HiAppAppearance") ?? HiAppAppearance.system.rawValue
        _appAppearance = Published(initialValue: HiAppAppearance(rawValue: raw) ?? .system)
    }

    var defaultEditMode: HiEditMode {
        get { defaultEditModeIsMarkdown ? .markdown : .html }
        set { defaultEditModeIsMarkdown = (newValue == .markdown) }
    }

    var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// HTML / Markdown rendering theme. Every visual element rendered by the
/// HTML editor (background, text, headings, accents, code, blockquote, list
/// markers, table borders, selection, hr) is driven by one of these fields,
/// so a user can wipe everything back to a stock look from Settings → Style.
struct AppTheme: Codable, Equatable {
    var baseFontSize: Double = 16
    /// Default uses the same modern Apple system stack as the welcome hero.
    var bodyFontName: String = AppTheme.defaultBodyFontStack
    var monoFontName: String = AppTheme.defaultMonoFontStack
    // Themed-dark default — matches the welcome hero (deep indigo bg,
    // brand-tinted headings/links). Light preset is still one click away
    // from Settings → Style.
    var pageBackground: String = "#0E0E1A"
    var textColor: String = "#E6E6F0"
    var headingColor: String = "#C7D2FE"
    var linkColor: String = "#A5B4FC"
    var codeBackground: String = "#1A1A2E"
    var blockquoteBorder: String = "#6366F1"
    /// Brand accent — drives h3/h4 color, list markers, hr, table borders,
    /// and the ::selection highlight. Editable from Settings.
    var accentColor: String = "#6366F1"
    var maxContentWidthPx: Double = 820

    static let `default` = AppTheme()

    /// Preset matching the welcome hero — deep indigo with brand accents.
    static let editorThemedPreset = AppTheme()

    /// Preset tuned for the HTML editor when the user wants a light page.
    static let editorLightPreset = AppTheme(
        pageBackground: "#FAFAFC",
        textColor: "#1A1A22",
        headingColor: "#1E1B4B",
        linkColor: "#4F46E5",
        codeBackground: "#EEF2FF",
        blockquoteBorder: "#6366F1",
        accentColor: "#6366F1"
    )

    /// Preset for a readable dark editor surface (independent of app chrome).
    static let editorDarkPreset = AppTheme(
        pageBackground: "#14141A",
        textColor: "#E8E8EF",
        headingColor: "#FFFFFF",
        linkColor: "#7EC8FF",
        codeBackground: "#1E1E28",
        blockquoteBorder: "#4A4A5C",
        accentColor: "#7DD3FC"
    )

    /// True if the user has ever explicitly saved a theme. We only inject
    /// COLOR variables into the WebView when this is true; otherwise we let
    /// the HTML's @media (prefers-color-scheme) rules pick light or dark
    /// defaults that match the app appearance. Typography (font / size /
    /// width) is always injected since it's appearance-independent.
    static var userHasCustomColors: Bool {
        UserDefaults.standard.data(forKey: "appTheme") != nil
    }

    static let defaultBodyFontStack = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"SF Pro Display\", \"Helvetica Neue\", sans-serif"
    static let defaultMonoFontStack = "ui-monospace, SFMono-Regular, Menlo, monospace"

    // Memberwise initializer (still synthesized, but explicit so the
    // custom Decodable init below doesn't suppress it).
    init(
        baseFontSize: Double = 16,
        bodyFontName: String = AppTheme.defaultBodyFontStack,
        monoFontName: String = AppTheme.defaultMonoFontStack,
        pageBackground: String = "#0E0E1A",
        textColor: String = "#E6E6F0",
        headingColor: String = "#C7D2FE",
        linkColor: String = "#A5B4FC",
        codeBackground: String = "#1A1A2E",
        blockquoteBorder: String = "#6366F1",
        accentColor: String = "#6366F1",
        maxContentWidthPx: Double = 820
    ) {
        self.baseFontSize = baseFontSize
        self.bodyFontName = bodyFontName
        self.monoFontName = monoFontName
        self.pageBackground = pageBackground
        self.textColor = textColor
        self.headingColor = headingColor
        self.linkColor = linkColor
        self.codeBackground = codeBackground
        self.blockquoteBorder = blockquoteBorder
        self.accentColor = accentColor
        self.maxContentWidthPx = maxContentWidthPx
    }

    private enum CodingKeys: String, CodingKey {
        case baseFontSize, bodyFontName, monoFontName
        case pageBackground, textColor, headingColor, linkColor
        case codeBackground, blockquoteBorder, accentColor, maxContentWidthPx
    }

    /// Tolerant decode — fields missing from older saved themes (e.g. when
    /// `accentColor` was added) fall back to the modern defaults instead of
    /// failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppTheme()
        baseFontSize = (try? c.decode(Double.self, forKey: .baseFontSize)) ?? d.baseFontSize
        bodyFontName = (try? c.decode(String.self, forKey: .bodyFontName)) ?? d.bodyFontName
        monoFontName = (try? c.decode(String.self, forKey: .monoFontName)) ?? d.monoFontName
        pageBackground = (try? c.decode(String.self, forKey: .pageBackground)) ?? d.pageBackground
        textColor = (try? c.decode(String.self, forKey: .textColor)) ?? d.textColor
        headingColor = (try? c.decode(String.self, forKey: .headingColor)) ?? d.headingColor
        linkColor = (try? c.decode(String.self, forKey: .linkColor)) ?? d.linkColor
        codeBackground = (try? c.decode(String.self, forKey: .codeBackground)) ?? d.codeBackground
        blockquoteBorder = (try? c.decode(String.self, forKey: .blockquoteBorder)) ?? d.blockquoteBorder
        accentColor = (try? c.decode(String.self, forKey: .accentColor)) ?? d.accentColor
        maxContentWidthPx = (try? c.decode(Double.self, forKey: .maxContentWidthPx)) ?? d.maxContentWidthPx
    }

    func cssVariablesJSON(includeColors: Bool) -> String {
        var dict: [String: String] = [
            "--md-base-font": bodyFontName,
            "--md-mono-font": monoFontName,
            "--md-base-size": "\(baseFontSize)px",
            "--md-max-width": "\(Int(maxContentWidthPx))px",
        ]
        if includeColors {
            dict["--md-page-bg"] = pageBackground
            dict["--md-text"] = textColor
            dict["--md-heading"] = headingColor
            dict["--md-link"] = linkColor
            dict["--md-code-bg"] = codeBackground
            dict["--md-bq-border"] = blockquoteBorder
            dict["--hi-brand"] = accentColor
        }
        let data = try! JSONEncoder().encode(dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func load() -> AppTheme {
        guard let data = UserDefaults.standard.data(forKey: "appTheme"),
              let t = try? JSONDecoder().decode(AppTheme.self, from: data)
        else { return .default }
        return t
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "appTheme")
        }
    }
}

// MARK: - Hex ↔︎ Color (Settings pickers)

private extension NSColor {
    convenience init?(hiHex: String) {
        var s = hiHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    func hiHexRGB() -> String {
        guard let c = usingColorSpace(.deviceRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private func colorPicker(_ hex: Binding<String>) -> some View {
    ColorPicker(
        "",
        selection: Binding(
            get: { Color(nsColor: NSColor(hiHex: hex.wrappedValue) ?? .labelColor) },
            set: { swift in
                guard let cg = swift.cgColor else { return }
                let ns = NSColor(cgColor: cg) ?? .labelColor
                hex.wrappedValue = ns.hiHexRGB()
            }
        )
    )
    .labelsHidden()
    .frame(width: 28, height: 22)
}

struct SettingsView: View {
    @EnvironmentObject private var settings: UserSettings
    @State private var theme = AppTheme.load()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            styleTab
                .tabItem { Label("Style", systemImage: "paintpalette") }
        }
        .frame(minWidth: 560, minHeight: 480)
        .tint(HiAppearance.brand)
        .onAppear { theme = AppTheme.load() }
    }

    private var generalTab: some View {
        VStack(spacing: 0) {
            settingsHeader(
                title: "General",
                subtitle: "Appearance and document defaults.",
                systemImage: "gearshape.fill"
            )
            Form {
                Section {
                    Picker("App appearance", selection: $settings.appAppearance) {
                        ForEach(HiAppAppearance.allCases) { a in
                            Text(a.title).tag(a)
                        }
                    }
                    Text("Controls the window chrome, sidebar, toolbar, and the HTML welcome screen. Editor colors live under Style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Default mode when opening a file", selection: Binding(
                        get: { settings.defaultEditMode },
                        set: { settings.defaultEditMode = $0 }
                    )) {
                        Text("HTML").tag(HiEditMode.html)
                        Text("Markdown").tag(HiEditMode.markdown)
                    }
                }

                Section {
                    LabeledContent("Created by") {
                        Link("rg1989", destination: HiAppearance.maintainerProfileURL)
                    }
                    Link("Source code on GitHub", destination: HiAppearance.projectRepositoryURL)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var styleTab: some View {
        VStack(spacing: 0) {
            settingsHeader(
                title: "Style",
                subtitle: "Every element rendered in the HTML view is editable below — pick a preset, then tweak.",
                systemImage: "paintpalette.fill"
            )
            Form {
                Section("Typography") {
                    TextField("Body font (CSS family stack)", text: $theme.bodyFontName)
                        .font(.system(.body, design: .monospaced))
                    TextField("Monospace font", text: $theme.monoFontName)
                        .font(.system(.body, design: .monospaced))
                    Stepper(value: $theme.baseFontSize, in: 10 ... 28, step: 1) {
                        Text("Base size: \(Int(theme.baseFontSize)) pt")
                    }
                    Stepper(value: $theme.maxContentWidthPx, in: 480 ... 1200, step: 20) {
                        Text("Max content width: \(Int(theme.maxContentWidthPx)) px")
                    }
                }

                Section("Quick presets") {
                    HStack(spacing: 8) {
                        presetButton("Themed", systemImage: "sparkles") { theme = .editorThemedPreset }
                        presetButton("Light", systemImage: "sun.max") { theme = .editorLightPreset }
                        presetButton("Dark", systemImage: "moon") { theme = .editorDarkPreset }
                    }
                }

                Section("Colors") {
                    colorRow("Page background", hex: $theme.pageBackground)
                    colorRow("Body text", hex: $theme.textColor)
                    colorRow("Headings", hex: $theme.headingColor)
                    colorRow("Links", hex: $theme.linkColor)
                    colorRow("Code blocks", hex: $theme.codeBackground)
                    colorRow("Blockquote border", hex: $theme.blockquoteBorder)
                    colorRow("Accent (h3 / h4, lists, dividers, selection)", hex: $theme.accentColor)
                }

                Section {
                    HStack {
                        Spacer()
                        Button {
                            theme.save()
                            NotificationCenter.default.post(name: .hiThemeChanged, object: nil)
                        } label: {
                            Label("Save style", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HiAppearance.brand)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func settingsHeader(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(HiAppearance.brand)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(HiAppearance.brand.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(HiAppearance.brand)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Rectangle().fill(.regularMaterial)
                LinearGradient(
                    colors: [
                        HiAppearance.brand.opacity(0.18),
                        HiAppearance.brand.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
        .overlay(
            HiAppearance.toolbarAccentLine(),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func presetButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(HiAppearance.brand)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("#RRGGBB", text: hex)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 100)
                colorPicker(hex)
            }
        } label: {
            Text(title)
        }
    }
}

struct FindReplaceSheet: View {
    @Binding var isPresented: Bool
    var isHTMLMode: Bool
    var onFindInMarkdown: (String) -> Void
    var onReplaceFirst: (String, String) -> Void
    var onReplaceAll: (String, String) -> Void
    var onFindInWeb: (String) -> Void

    @State private var find = ""
    @State private var replace = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find & Replace").font(.headline)
            TextField("Find", text: $find)
                .textFieldStyle(.roundedBorder)
            TextField("Replace", text: $replace)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Find Next") {
                    if isHTMLMode {
                        onFindInWeb(find)
                    } else {
                        onFindInMarkdown(find)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("Replace") {
                    onReplaceFirst(find, replace)
                }
                Button("Replace All") {
                    onReplaceAll(find, replace)
                }
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            if isHTMLMode {
                Text("Tip: native Find also works in HTML mode (⌘F triggers this panel; use Edit menu Find for web find where available).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }
}
