// ─────────────────────────────────────────────────────────────────────────────
// FORMApp.swift
// FORM iOS Shell — v4.1
//
// Single file. Drop into Xcode replacing FORMApp.swift.
// No other Swift files required.
//
// v4 changes over v3:
//   — Bottom spine always navigates to chapter root (not passive reselect)
//   — Reading memory per chapter: lastReadURL / lastReadTitle
//     · persists across launches as quiet ambient memory
//     · surfaces as "Continue" row in drawer only when meaningful
//     · never overrides cold launch or spine behavior
//   — Top frame title hierarchy: page title → chapter → FORM
//   — goHome() normalises Home state fully (URL + title + canGoBack)
//   — Cache reset utility in drawer (Testing section, remove before App Store)
//   — Drawer row spacing tightened; section headers cleaned up
//   — Bottom spine font 13, padding 16, underline 1.5pt
//   — bounces = false (restrained motion, manual feel)
//   — Chapter URL membership helper for reading-memory gating
//   — Generic title suppression applied consistently
//
// Navigation hierarchy (invariant):
//   Cold launch    → Home root
//   Bottom spine   → chapter root
//   Back button    → local webview history
//   Drawer / Index → chapter map + Continue + tools
//   Field Marks    → explicitly saved pages (separate from shell)
//
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import WebKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Constants
// ─────────────────────────────────────────────────────────────────────────────

private let sharedProcessPool = WKProcessPool()

// Generic page titles that carry no useful orientation information.
private let genericTitles: Set<String> = [
    "FORM", "speedandform.com", "Speed and Form", "", " "
]

private func isMeaningfulTitle(_ title: String) -> Bool {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return !t.isEmpty && !genericTitles.contains(t)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Scheme policy
//
// All speedandform.com subdomains allowed so CDN assets and media load.
// ─────────────────────────────────────────────────────────────────────────────

private enum SchemeAction {
    case allowInShell
    case openExternal(URL)
    case cancel
}

private func schemePolicy(for url: URL) -> SchemeAction {
    switch url.scheme?.lowercased() {
    case "https", "http":
        let host = url.host ?? ""
        return host.hasSuffix("speedandform.com") ? .allowInShell : .openExternal(url)
    case "mailto", "tel", "sms":
        return .openExternal(url)
    default:
        return .cancel
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Load intent
// ─────────────────────────────────────────────────────────────────────────────

struct LoadIntent: Equatable {
    let id:      UUID
    let request: URLRequest

    init(url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) {
        self.id      = UUID()
        self.request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 30)
    }

    static func == (lhs: LoadIntent, rhs: LoadIntent) -> Bool { lhs.id == rhs.id }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Destinations
// ─────────────────────────────────────────────────────────────────────────────

enum FORMDestination: String, CaseIterable, Identifiable {
    case home      = "home"
    case threshold = "threshold"
    case longRun   = "longRun"
    case reference = "reference"
    case athletes  = "athletes"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:      return "Home"
        case .threshold: return "Threshold"
        case .longRun:   return "Long Run"
        case .reference: return "Reference"
        case .athletes:  return "Athletes"
        }
    }

    var rootURL: URL {
        switch self {
        case .home:      return URL(string: "https://speedandform.com/")!
        case .threshold: return URL(string: "https://speedandform.com/threshold")!
        case .longRun:   return URL(string: "https://speedandform.com/long-run")!
        case .reference: return URL(string: "https://speedandform.com/library")!
        case .athletes:  return URL(string: "https://speedandform.com/athletes")!
        }
    }

    // Determines whether a URL belongs to this chapter for reading-memory gating.
    func owns(url: URL) -> Bool {
        let path = url.path.lowercased()
        switch self {
        case .home:
            // Home owns pages that don't belong to other chapters
            let otherPaths = ["/threshold", "/long-run", "/library", "/recovery",
                              "/fueling", "/sleep", "/pacing", "/athletes", "/ledger"]
            return !otherPaths.contains(where: { path.hasPrefix($0) })
        case .threshold:
            return path.hasPrefix("/threshold")
        case .longRun:
            return path.hasPrefix("/long-run")
        case .reference:
            return path.hasPrefix("/library") || path.hasPrefix("/recovery") ||
                   path.hasPrefix("/fueling") || path.hasPrefix("/sleep") ||
                   path.hasPrefix("/pacing")  || path.hasPrefix("/speed-sessions") ||
                   path.hasPrefix("/reference")
        case .athletes:
            return path.hasPrefix("/athletes") || path.hasPrefix("/ledger")
        }
    }

    // Contextual pages shown in the drawer under "In this chapter".
    var drawerPages: [(label: String, url: URL)] {
        switch self {
        case .home:
            return [
                ("Practice",       URL(string: "https://speedandform.com/practice")!),
                ("Method",         URL(string: "https://speedandform.com/method")!),
                ("Plan",           URL(string: "https://speedandform.com/plan")!),
                ("Strength",       URL(string: "https://speedandform.com/strength")!),
                ("Cycles",         URL(string: "https://speedandform.com/cycles")!),
                ("The Work",       URL(string: "https://speedandform.com/the-work")!),
                ("Interruptions",  URL(string: "https://speedandform.com/interruptions")!),
                ("The Field",      URL(string: "https://speedandform.com/the-field")!),
            ]
        case .threshold:
            return [
                ("Threshold",      URL(string: "https://speedandform.com/threshold")!),
            ]
        case .longRun:
            return [
                ("Long Run",       URL(string: "https://speedandform.com/long-run")!),
            ]
        case .reference:
            return [
                ("Library",        URL(string: "https://speedandform.com/library")!),
                ("Recovery",       URL(string: "https://speedandform.com/recovery")!),
                ("Fueling",        URL(string: "https://speedandform.com/fueling")!),
                ("Sleep",          URL(string: "https://speedandform.com/sleep")!),
                ("Pacing",         URL(string: "https://speedandform.com/pacing")!),
            ]
        case .athletes:
            return [
                ("Athletes",       URL(string: "https://speedandform.com/athletes")!),
                ("Ledger",         URL(string: "https://speedandform.com/ledger")!),
            ]
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Section state
// ─────────────────────────────────────────────────────────────────────────────

struct FORMSectionState {
    var currentURL:    String      = ""
    var currentTitle:  String      = ""
    var canGoBack:     Bool        = false
    var loadIntent:    LoadIntent? = nil
    // Reading memory — persists across launches, surfaces as Continue in drawer
    var lastReadURL:   String?     = nil
    var lastReadTitle: String?     = nil
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — WebView registry
// ─────────────────────────────────────────────────────────────────────────────

final class FORMWebViewRegistry {
    private var storage: [FORMDestination: WKWebView] = [:]
    subscript(dest: FORMDestination) -> WKWebView? {
        get { storage[dest] }
        set { storage[dest] = newValue }
    }
    /// Release all non-Home webview references so they can be deallocated.
    /// Called during cache reset when initializedChapters collapses to [.home].
    func removeNonHome() {
        FORMDestination.allCases.filter { $0 != .home }.forEach { storage.removeValue(forKey: $0) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native navigation store
//
// Lightweight intent bus for native chapter sub-page routing.
// Shell URL routing handles webview chapters (Athletes).
// Native chapters (Home/Practice, Reference) use this instead.
//
// Law: shell.navigate() is for URL/webview chapters only.
//       NativeNavStore is for state-driven native chapters.
//
// Drawer fires nativePracticePage / nativeReferencePage.
// Native containers observe and set their local selectedPage accordingly.
// No URL involved. No shell state changes for native sub-pages.
// ─────────────────────────────────────────────────────────────────────────────

final class NativeNavStore: ObservableObject {
    @Published var practicePage:  PracticePage?  = nil
    @Published var referencePage: ReferencePage? = nil

    func navigate(to page: PracticePage)  { practicePage  = page }
    func navigate(to page: ReferencePage) { referencePage = page }
    func clearPractice()  { practicePage  = nil }
    func clearReference() { referencePage = nil }

    // Called by bottom spine and drawer chapter-root taps.
    // Resets the relevant native chapter to its root.
    func resetToRoot(for dest: FORMDestination) {
        switch dest {
        case .home:      practicePage  = nil
        case .reference: referencePage = nil
        default:         break
        }
    }
}




final class FORMShellStore: ObservableObject {
    @Published var selected: FORMDestination = .home
    @Published var sections: [FORMDestination: FORMSectionState]
    /// Chapters whose WKWebView has been created. Home is always first.
    /// All others are initialized lazily on first open.
    @Published var initializedChapters: Set<FORMDestination> = [.home]

    private let registry = FORMWebViewRegistry()

    // UserDefaults keys for reading memory persistence
    private func lastReadURLKey(_ dest: FORMDestination)   -> String { "lastReadURL_\(dest.rawValue)" }
    private func lastReadTitleKey(_ dest: FORMDestination) -> String { "lastReadTitle_\(dest.rawValue)" }

    init() {
        var s: [FORMDestination: FORMSectionState] = [:]
        FORMDestination.allCases.forEach { dest in
            var state = FORMSectionState()
            state.currentURL   = dest.rootURL.absoluteString
            state.currentTitle = dest.label
            // Restore reading memory from prior launches
            state.lastReadURL   = UserDefaults.standard.string(forKey: "lastReadURL_\(dest.rawValue)")
            state.lastReadTitle = UserDefaults.standard.string(forKey: "lastReadTitle_\(dest.rawValue)")
            s[dest] = state
        }
        self.sections = s
    }

    // MARK: Derived accessors
    func state(for dest: FORMDestination) -> FORMSectionState { sections[dest] ?? FORMSectionState() }
    var activeState:     FORMSectionState { state(for: selected) }
    var activeURL:       String           { activeState.currentURL }
    var activeTitle:     String           { activeState.currentTitle }
    var activeCanGoBack: Bool             { activeState.canGoBack }

    // Top frame title hierarchy:
    //   Home root / no title → "FORM"
    //   Meaningful live page title → page title
    //   Loading (blank title, not at root) → last-read title as stable placeholder
    //   Otherwise → chapter label
    var topFrameLabel: String {
        let title  = activeState.currentTitle
        let isHome = selected == .home
        let atRoot = activeURL.isEmpty || activeURL == selected.rootURL.absoluteString
        if isHome && atRoot && !isMeaningfulTitle(title) { return "FORM" }
        if isMeaningfulTitle(title) { return title }
        if !atRoot,
           let lastTitle = activeState.lastReadTitle,
           isMeaningfulTitle(lastTitle) { return lastTitle }
        return isHome ? "FORM" : selected.label
    }

    // MARK: WebView registry
    func register(_ wv: WKWebView, for dest: FORMDestination) { registry[dest] = wv }
    func webView(for dest: FORMDestination) -> WKWebView?     { registry[dest] }

    // MARK: State updates (called from WebView coordinator)
    func setURL(_ url: String, for dest: FORMDestination)      { sections[dest]?.currentURL   = url }
    func setTitle(_ title: String, for dest: FORMDestination)  { sections[dest]?.currentTitle = title }
    func setCanGoBack(_ v: Bool, for dest: FORMDestination)    { sections[dest]?.canGoBack    = v }

    // MARK: Reading memory
    func setLastRead(url: String, title: String, for dest: FORMDestination) {
        guard let pageURL = URL(string: url), dest.owns(url: pageURL) else { return }
        guard isMeaningfulTitle(title) else { return }
        // Don't store if it's the root URL — not useful as a resume point
        guard url != dest.rootURL.absoluteString else { return }
        sections[dest]?.lastReadURL   = url
        sections[dest]?.lastReadTitle = title
        UserDefaults.standard.set(url,   forKey: lastReadURLKey(dest))
        UserDefaults.standard.set(title, forKey: lastReadTitleKey(dest))
    }

    func hasMeaningfulLastRead(for dest: FORMDestination) -> Bool {
        guard let url = sections[dest]?.lastReadURL,
              !url.isEmpty,
              url != dest.rootURL.absoluteString,
              let title = sections[dest]?.lastReadTitle,
              isMeaningfulTitle(title)
        else { return false }
        return true
    }

    // MARK: Navigation actions

    // Bottom spine: always load chapter root (never passive reselect).
    // Marks chapter initialized (creates its WKWebView lazily on first visit),
    // then normalises visible state immediately before issuing the load intent
    // so the top frame never briefly shows a stale title or Back button.
    func selectChapter(_ dest: FORMDestination) {
        initializedChapters.insert(dest)
        sections[dest]?.currentURL   = dest.rootURL.absoluteString
        sections[dest]?.currentTitle = dest.label
        sections[dest]?.canGoBack    = false
        selected                     = dest
        sections[dest]?.loadIntent   = LoadIntent(url: dest.rootURL)
    }

    // Internal navigate (drawer, marks, etc.).
    // Marks chapter initialized on first cross-chapter jump.
    // Clears stale title when crossing chapter boundary.
    func navigate(to dest: FORMDestination, url: URL) {
        initializedChapters.insert(dest)
        if selected != dest {
            sections[dest]?.currentURL   = url.absoluteString
            sections[dest]?.currentTitle = ""
            sections[dest]?.canGoBack    = false
        }
        selected                   = dest
        sections[dest]?.loadIntent = LoadIntent(url: url)
    }

    func goBack() {
        registry[selected]?.goBack()
    }

    // Return to Home cover — normalise all Home state
    func goHome() {
        selected = .home
        sections[.home]?.currentURL   = FORMDestination.home.rootURL.absoluteString
        sections[.home]?.currentTitle = "Home"
        sections[.home]?.canGoBack    = false
        sections[.home]?.loadIntent   = LoadIntent(url: FORMDestination.home.rootURL)
    }

    func resetToRoot(_ dest: FORMDestination) {
        sections[dest]?.loadIntent   = LoadIntent(url: dest.rootURL)
        sections[dest]?.currentURL   = dest.rootURL.absoluteString
        sections[dest]?.currentTitle = dest.label
        sections[dest]?.canGoBack    = false
    }

    // Cache reset — clears WKWebView website data and reloads all chapters fresh.
    // Also collapses initializedChapters back to [.home] so non-Home webviews
    // are released and re-created lazily on next visit (fully clears stale content).
    func clearCacheAndReload() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async {
                    self.selected             = .home
                    self.initializedChapters  = [.home]
                    self.registry.removeNonHome()   // release stale webview refs
                    FORMDestination.allCases.forEach { dest in
                        self.sections[dest]?.currentURL   = dest.rootURL.absoluteString
                        self.sections[dest]?.currentTitle = dest.label
                        self.sections[dest]?.canGoBack    = false
                        self.sections[dest]?.loadIntent   = LoadIntent(
                            url: dest.rootURL,
                            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
                        )
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Field Mark model (separate from shell state)
// ─────────────────────────────────────────────────────────────────────────────

struct FieldMark: Codable, Identifiable, Equatable {
    let id:          UUID
    let title:       String
    let destination: String
    let url:         String
    let savedAt:     Date

    init(title: String, destination: FORMDestination, url: String) {
        self.id          = UUID()
        self.title       = title
        self.destination = destination.rawValue
        self.url         = url
        self.savedAt     = Date()
    }

    var destinationEnum: FORMDestination? { FORMDestination(rawValue: destination) }
}

private let fieldMarksKey = "fieldMarks"
private let fieldMarksCap = 30

final class FieldMarksStore: ObservableObject {
    @Published private(set) var marks: [FieldMark] = []

    init() { load() }

    func isSaved(url: String) -> Bool { marks.contains { $0.url == url } }

    func toggle(title: String, destination: FORMDestination, url: String) {
        if let idx = marks.firstIndex(where: { $0.url == url }) {
            marks.remove(at: idx)
        } else {
            marks.insert(FieldMark(title: title, destination: destination, url: url), at: 0)
            if marks.count > fieldMarksCap { marks = Array(marks.prefix(fieldMarksCap)) }
        }
        save()
    }

    func remove(at offsets: IndexSet) { marks.remove(atOffsets: offsets); save() }

    private func load() {
        guard let data    = UserDefaults.standard.data(forKey: fieldMarksKey),
              let decoded = try? JSONDecoder().decode([FieldMark].self, from: data)
        else { return }
        marks = decoded
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        UserDefaults.standard.set(data, forKey: fieldMarksKey)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Mark title helper
// ─────────────────────────────────────────────────────────────────────────────

private func resolveMarkTitle(pageTitle: String, sectionLabel: String, url: String) -> String {
    if isMeaningfulTitle(pageTitle) { return pageTitle }
    if !sectionLabel.isEmpty { return sectionLabel }
    return url
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — FORM palette
// ─────────────────────────────────────────────────────────────────────────────

extension Color {
    // ── Shell palette (used by webview shell, drawer, spine) ─────────────────
    static let formCream    = Color(red: 0.961, green: 0.949, blue: 0.925)
    static let formInk      = Color(red: 0.165, green: 0.149, blue: 0.125)
    static let formInkLight = Color(red: 0.420, green: 0.392, blue: 0.349)
    static let formInkFaint = Color(red: 0.627, green: 0.596, blue: 0.565)
    static let formLine     = Color(red: 0.847, green: 0.824, blue: 0.784)

    // ── Native page palette (Practice, Threshold, Long Run, all future pages) ─
    // All native pages read from here. PC enum is retired.
    //
    // titleInk  #2e2a24 — warm near-black; dominant typographic moments
    // bodyInk   #3a3530 — session names, primary body text
    // secondary #5c5549 — detail lines, doctrine primary line
    // faint     #a09890 — labels, metadata, rules, recessive cues
    // rule      #d8d2c8 — structural dividers at 0.5pt
    // cream     #f5f2ec — page ground (identical to formCream)
    static let nativeTitleInk  = Color(red: 0.220, green: 0.200, blue: 0.170)
    static let nativeBodyInk   = Color(red: 0.270, green: 0.248, blue: 0.220)
    static let nativeSecondary = Color(red: 0.420, green: 0.390, blue: 0.345)
    static let nativeFaint     = Color(red: 0.650, green: 0.622, blue: 0.588)
    static let nativeRule      = Color(red: 0.855, green: 0.835, blue: 0.800)
    static let nativeCream     = Color(red: 0.965, green: 0.953, blue: 0.930)
}

extension UIColor {
    static let formCream = UIColor(red: 0.961, green: 0.949, blue: 0.925, alpha: 1)
    static let formInk   = UIColor(red: 0.165, green: 0.149, blue: 0.125, alpha: 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Failure view
// ─────────────────────────────────────────────────────────────────────────────

struct FORMFailureView: View {
    let onRetry: () -> Void
    var body: some View {
        ZStack {
            Color.formCream.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("FORM")
                    .font(.custom("Georgia", size: 28))
                    .foregroundColor(.formInk)
                    .tracking(2)
                Text("Connection unavailable")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(.formInkLight)
                Button(action: onRetry) {
                    Text("Try Again")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.formInkFaint)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.formLine, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Field Marks sheet
// ─────────────────────────────────────────────────────────────────────────────

struct FieldMarksSheet: View {
    @EnvironmentObject var marksStore: FieldMarksStore
    let onNavigate: (FORMDestination, URL) -> Void
    @Environment(\.dismiss) private var dismiss

    private func navigate(mark: FieldMark) {
        guard let dest = mark.destinationEnum,
              let url  = URL(string: mark.url),
              url.scheme == "https",
              let host = url.host,
              host.hasSuffix("speedandform.com")
        else { return }
        onNavigate(dest, url)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.formCream.ignoresSafeArea()
                if marksStore.marks.isEmpty {
                    VStack(spacing: 10) {
                        Text("No marked pages")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(.formInkLight)
                        Text("Mark any page using ◇ in the Index")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.formInkFaint)
                    }
                } else {
                    List {
                        ForEach(marksStore.marks) { mark in
                            Button { navigate(mark: mark) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mark.title)
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundColor(.formInk)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(mark.destinationEnum?.label ?? mark.destination)
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.formInkFaint)
                                        Text("·")
                                            .foregroundColor(.formInkFaint)
                                            .font(.system(size: 11, weight: .regular))
                                        Text(mark.savedAt, style: .date)
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.formInkFaint)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.formCream)
                        }
                        .onDelete { marksStore.remove(at: $0) }
                    }
                    .listStyle(.plain)
                    .background(Color.formCream)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Field Marks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.formCream, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 13, weight: .regular)).foregroundColor(.formInkLight)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                        .font(.system(size: 13, weight: .regular)).foregroundColor(.formInkLight)
                        .disabled(marksStore.marks.isEmpty)
                        .opacity(marksStore.marks.isEmpty ? 0 : 1)
                }
            }
        }
        .accentColor(.formInk)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Drawer (Index)
//
// Three sections: Chapters / In this chapter (+ Continue) / Tools
// Testing section at bottom — remove before App Store submission.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMDrawer: View {
    @ObservedObject var shell:    FORMShellStore
    @ObservedObject var nativeNav: NativeNavStore
    @EnvironmentObject var marks: FieldMarksStore
    let onNavigate:   (FORMDestination, URL) -> Void
    let onShowMarks:  () -> Void
    let onToggleMark: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var shareURL: URL? {
        guard !shell.activeURL.isEmpty,
              let url  = URL(string: shell.activeURL),
              url.scheme == "https",
              let host = url.host,
              host.hasSuffix("speedandform.com")
        else { return nil }
        return url
    }

    // Native chapters own their routing state. Shell URL tools are not
    // authoritative there — Continue / Mark / Share must be hidden.
    private var isNativeChapter: Bool {
        shell.selected == .home || shell.selected == .reference
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.formCream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // ── Section 1: Chapters ──────────────────────────
                        sectionHeader("Chapters")
                        ForEach(FORMDestination.allCases) { dest in
                            drawerRow(
                                label: dest.label,
                                isActive: shell.selected == dest
                            ) {
                                nativeNav.resetToRoot(for: dest)   // reset native sub-page state
                                onNavigate(dest, dest.rootURL)
                                dismiss()
                            }
                        }

                        sectionDivider()

                        // ── Section 2: Practice ──────────────────────────
                        sectionHeader("Practice")

                        // Root Practice row — reset chapter to ledger
                        drawerRow(
                            label: "Practice",
                            isActive: shell.selected == .home && nativeNav.practicePage == nil
                        ) {
                            nativeNav.resetToRoot(for: .home)
                            onNavigate(.home, FORMDestination.home.rootURL)
                            dismiss()
                        }

                        // Practice sub-pages — always visible, use NativeNavStore
                        ForEach(PracticePage.allCases, id: \.self) { page in
                            drawerRow(
                                label: page.rawValue,
                                isActive: shell.selected == .home && nativeNav.practicePage == page
                            ) {
                                nativeNav.navigate(to: page)
                                onNavigate(.home, FORMDestination.home.rootURL)
                                dismiss()
                            }
                        }

                        // ── Section 3: Reference ────────────────────────
                        sectionHeader("Reference")

                        // Root Reference row — reset chapter to ledger
                        drawerRow(
                            label: "Reference",
                            isActive: shell.selected == .reference && nativeNav.referencePage == nil
                        ) {
                            nativeNav.resetToRoot(for: .reference)
                            onNavigate(.reference, FORMDestination.reference.rootURL)
                            dismiss()
                        }

                        // Reference sub-pages — always visible, use NativeNavStore
                        ForEach(ReferencePage.allCases, id: \.self) { page in
                            drawerRow(
                                label: page.rawValue,
                                isActive: shell.selected == .reference && nativeNav.referencePage == page
                            ) {
                                nativeNav.navigate(to: page)
                                onNavigate(.reference, FORMDestination.reference.rootURL)
                                dismiss()
                            }
                        }

                        sectionDivider()

                        // ── Section 3: Tools ─────────────────────────────
                        sectionHeader("Tools")

                        // Mark this page — URL-backed. Hidden for native chapters.
                        if !isNativeChapter {
                            Button {
                                onToggleMark()
                                dismiss()
                            } label: {
                                HStack {
                                    Text(marks.isSaved(url: shell.activeURL) ? "Remove mark" : "Mark this page")
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(shell.activeURL.isEmpty ? .formInkFaint : .formInkLight)
                                    Spacer()
                                    Text(marks.isSaved(url: shell.activeURL) ? "◆" : "◇")
                                        .font(.system(size: 11))
                                        .foregroundColor(.formInkFaint)
                                }
                                .padding(.horizontal, 24).padding(.vertical, 11)
                            }
                            .buttonStyle(.plain)
                            .disabled(shell.activeURL.isEmpty)
                            thinLine()
                        }

                        // Field Marks — global list, always available
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onShowMarks() }
                        } label: {
                            HStack {
                                Text("Field Marks")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.formInkLight)
                                Spacer()
                                if marks.marks.count > 0 {
                                    Text("\(marks.marks.count)")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(.formInkFaint)
                                }
                            }
                            .padding(.horizontal, 24).padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        thinLine()

                        // Share page — URL-backed. Hidden for native chapters.
                        if !isNativeChapter {
                            if #available(iOS 16, *), let url = shareURL {
                                ShareLink(item: url) {
                                    HStack {
                                        Text("Share page")
                                            .font(.system(size: 14, weight: .regular))
                                            .foregroundColor(.formInkLight)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 11)
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack {
                                    Text("Share page")
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(.formInkFaint)
                                    Spacer()
                                }
                                .padding(.horizontal, 24).padding(.vertical, 11)
                            }
                        }

                        // ── Testing only — remove before App Store submission ─
                        sectionDivider()
                        sectionHeader("Testing · remove before release")

                        Button {
                            shell.clearCacheAndReload()
                            dismiss()
                        } label: {
                            HStack {
                                Text("Reset Cache")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(.formInkFaint)
                                Spacer()
                                Text("↺")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundColor(.formInkFaint)
                            }
                            .padding(.horizontal, 24).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Custom drawer header — owns all colors, no system nav-bar ambiguity.
                // "Index" in Georgia with letter-spacing: this is a FORM surface.
                // "Close" is light system font: a control, not a label.
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        Button("Close") { dismiss() }
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.formInkFaint)
                            .accessibilityLabel("Close Index")
                        Spacer()
                        // Center: FORM typographic identity — the one place serif lives in the shell
                        Text("Index")
                            .font(.custom("Georgia", size: 17))
                            .foregroundColor(.formInk)
                            .tracking(1.5)
                        Spacer()
                        // Invisible balance placeholder — keeps Index optically centered
                        Text("Close")
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.clear)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(Color.formCream)
                    Rectangle()
                        .fill(Color.formLine.opacity(0.35))
                        .frame(height: 0.5)
                }
                .background(Color.formCream)
            }
        }
        .accentColor(.formInk)
    }

    // MARK: Drawer sub-views

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(Color(red: 0.627, green: 0.596, blue: 0.565).opacity(0.7))
            .tracking(2.5)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func drawerRow(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center) {
                Text(label)
                    .font(.system(size: isActive ? 15 : 14, weight: isActive ? .medium : .regular))
                    // Active: full ink. Inactive: quieter — easier for the eye to pass over
                    .foregroundColor(isActive ? .formInk : Color(red: 0.42, green: 0.392, blue: 0.349).opacity(0.75))
                Spacer()
                // Active indicator: short rule, right-aligned, slightly more refined
                if isActive {
                    Rectangle()
                        .fill(Color.formInk.opacity(0.5))
                        .frame(width: 12, height: 0.75)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        thinLine()
    }

    @ViewBuilder
    private func thinLine() -> some View {
        Rectangle()
            .fill(Color.formLine.opacity(0.45))
            .frame(height: 0.5)
            .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func sectionDivider() -> some View {
        Rectangle()
            .fill(Color.formLine.opacity(0.5))
            .frame(height: 0.5)
            .padding(.top, 10)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Top frame
//
// Back (left, only when available) · blank center · Index (right)
// Intentionally recessive — the rail should stop being noticed after 10 seconds.
// Controls at formInkFaint weight. Divider barely visible. 36pt height.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMTopFrame: View {
    let canGoBack:  Bool
    let label:      String   // retained for accessibility; not displayed
    let onBack:     () -> Void
    let onIndex:    () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                // Left: chapter roots show "FORM" — book identity, rail never empty.
                // Deeper pages show "Back" — local history control.
                if canGoBack {
                    Button(action: onBack) {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .regular))
                            Text("Back")
                                .font(.system(size: 12, weight: .light))
                        }
                        .foregroundColor(.formInkFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go back")
                    .transition(.opacity)
                } else {
                    Text("FORM")
                        .font(.custom("Georgia", size: 12))
                        .foregroundColor(.formInkFaint)
                        .tracking(0.8)
                        .transition(.opacity)
                }

                Spacer()

                // Right: Index — barely there, always reachable
                Button(action: onIndex) {
                    Text("Index")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.formInkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Index")
            }
            .padding(.horizontal, 20)
            .frame(height: 36)

            // Divider: barely visible — framing edge, not a design element
            Rectangle()
                .fill(Color.formLine.opacity(0.35))
                .frame(height: 0.5)
        }
        .background(Color.formCream)
        .animation(.easeInOut(duration: 0.12), value: canGoBack)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Bottom spine
//
// Chapter spine — typographic, deliberate, not a tab bar.
// Cormorant Garamond: active chapter in full ink, inactive in faint.
// Active underline: narrow, centered, proportional to label width.
// Lifted from home indicator. Feels like a running index, not navigation chrome.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMBottomSpine: View {
    @ObservedObject var shell:     FORMShellStore
    @ObservedObject var nativeNav: NativeNavStore

    var body: some View {
        VStack(spacing: 0) {
            // Top edge: very faint — just enough to separate from content
            Rectangle()
                .fill(Color.formLine.opacity(0.4))
                .frame(height: 0.5)

            HStack(spacing: 0) {
                ForEach(FORMDestination.allCases) { dest in
                    let isActive = shell.selected == dest
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            nativeNav.resetToRoot(for: dest)   // reset native sub-page first
                            shell.selectChapter(dest)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(dest.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(isActive ? NativePalette.titleInk : NativePalette.secondary)
                                .tracking(0.1)

                            // Active indicator — wider, slightly heavier, easy to catch
                            Rectangle()
                                .fill(isActive ? NativePalette.titleInk.opacity(0.7) : Color.clear)
                                .frame(width: 20, height: 1.5)
                        }
                        .padding(.top, 18)
                        .padding(.bottom, 34)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dest.label)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .background(Color.formCream)
        }
        .background(Color.formCream)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — WebView (UIViewRepresentable)
// ─────────────────────────────────────────────────────────────────────────────

struct FORMWebView: UIViewRepresentable {
    let destination: FORMDestination
    let shell:       FORMShellStore
    @Binding var isLoaded:             Bool
    @Binding var hasFailed:            Bool
    @Binding var lastAttemptedRequest: URLRequest?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore  = WKWebsiteDataStore.default()
        config.processPool       = sharedProcessPool
        config.allowsInlineMediaPlayback = true
        // javaScriptEnabled deprecated iOS 14 — use allowsContentJavaScript instead
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences  = pagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate         = context.coordinator
        wv.scrollView.contentInsetAdjustmentBehavior = .automatic
        wv.scrollView.bounces = false          // restrained motion, manual feel
        wv.backgroundColor    = .formCream
        wv.isOpaque           = false
        wv.allowsBackForwardNavigationGestures = true   // swipe-back

        shell.register(wv, for: destination)

        // If a loadIntent was set before this webview existed (e.g. first cross-chapter
        // deep navigation from drawer or Field Marks), honour it as the initial load.
        // Otherwise fall back to the chapter root (standard cold/spine launch).
        let initialRequest: URLRequest
        if let pending = shell.state(for: destination).loadIntent?.request {
            initialRequest = pending
        } else {
            initialRequest = URLRequest(url: destination.rootURL)
        }
        context.coordinator.lastAttemptedRequest = initialRequest
        wv.load(initialRequest)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(destination: destination, shell: shell,
                    isLoaded: $isLoaded, hasFailed: $hasFailed,
                    lastAttemptedRequest: $lastAttemptedRequest)
    }

    // ─────────────────────────────────────────────────────────────────────────
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let destination: FORMDestination
        let shell:       FORMShellStore
        @Binding var isLoaded:             Bool
        @Binding var hasFailed:            Bool
        @Binding var lastAttemptedRequest: URLRequest?

        init(destination: FORMDestination, shell: FORMShellStore,
             isLoaded: Binding<Bool>, hasFailed: Binding<Bool>,
             lastAttemptedRequest: Binding<URLRequest?>) {
            self.destination           = destination
            self.shell                 = shell
            self._isLoaded             = isLoaded
            self._hasFailed            = hasFailed
            self._lastAttemptedRequest = lastAttemptedRequest
        }

        func webView(_ wv: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            withAnimation(.easeIn(duration: 0.1)) { isLoaded = false; hasFailed = false }
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            if let url = wv.url?.absoluteString {
                let title = wv.title ?? ""
                shell.setURL(url, for: destination)
                shell.setTitle(title, for: destination)
                shell.setCanGoBack(wv.canGoBack, for: destination)
                // Update reading memory — ambient, quiet
                shell.setLastRead(url: url, title: title, for: destination)
            }
            withAnimation(.easeOut(duration: 0.2)) { isLoaded = true }
            wv.scrollView.flashScrollIndicators()
        }

        func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            withAnimation { isLoaded = true; hasFailed = true }
        }

        func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            withAnimation { isLoaded = true; hasFailed = true }
        }

        func webView(_ wv: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            switch schemePolicy(for: url) {
            case .allowInShell:
                lastAttemptedRequest = action.request
                shell.setURL(url.absoluteString, for: destination)
                shell.setTitle("", for: destination)
                shell.setCanGoBack(shell.webView(for: destination)?.canGoBack ?? false, for: destination)
                decisionHandler(.allow)
            case .openExternal(let u):
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func webView(_ wv: WKWebView,
                     createWebViewWith _: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            switch schemePolicy(for: url) {
            case .allowInShell:
                lastAttemptedRequest = action.request
                shell.setURL(url.absoluteString, for: destination)
                shell.setTitle("", for: destination)
                shell.webView(for: destination)?.load(action.request)
            case .openExternal(let u):
                UIApplication.shared.open(u)
            case .cancel:
                break
            }
            return nil
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Section view (one per chapter, all kept in memory)
// ─────────────────────────────────────────────────────────────────────────────

struct FORMSectionView: View {
    let destination: FORMDestination
    @ObservedObject var shell: FORMShellStore

    @State private var isLoaded:             Bool        = false
    @State private var hasFailed:            Bool        = false
    @State private var lastAttemptedRequest: URLRequest? = nil
    @State private var lastIntentID:         UUID?       = nil

    var body: some View {
        ZStack {
            Color.formCream.ignoresSafeArea()

            FORMWebView(
                destination:          destination,
                shell:                shell,
                isLoaded:             $isLoaded,
                hasFailed:            $hasFailed,
                lastAttemptedRequest: $lastAttemptedRequest
            )

            // No loading text — cream background, page arrives quietly

            if isLoaded && hasFailed {
                FORMFailureView {
                    let req = lastAttemptedRequest ?? URLRequest(url: destination.rootURL)
                    lastAttemptedRequest = req
                    shell.webView(for: destination)?.load(req)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: shell.state(for: destination).loadIntent) { _, intent in
            guard let intent, intent.id != lastIntentID else { return }
            DispatchQueue.main.async {
                lastIntentID = intent.id
                lastAttemptedRequest = intent.request
                shell.webView(for: destination)?.load(intent.request)
            }
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Practice page (v1.9 — FORMReadingFrame chassis)
//
// Carries v1.4 readability base throughout.
// One consistent row grammar — no alternate row architectures.
// Two targeted refinements only:
//
//   TODAY EMPHASIS
//   — isToday row: rule opacity 0.38 → 0.65 (top and bottom), session name
//     +1pt, day label slightly darker and tracked wider, small "today" mark
//     sits below the detail line in faint small-caps. Discovered, not announced.
//
//   DOCTRINE HIERARCHY
//   — "Stay in the room." remains primary: 18pt italic, NativePalette.secondary.
//   — Execution cue steps back: 12pt (was 13), NativePalette.faint (was NativePalette.secondary).
//     It supports the doctrine line rather than matching its weight.
//     Still readable; just recessive.
// ─────────────────────────────────────────────────────────────────────────────

// ── FORMPressStyle ────────────────────────────────────────────────────────────
// Clean press feedback for all tappable native rows.
// Uses SwiftUI's natural touch state — no DragGesture interference with scrolling.
// Opacity dips to 0.62 on press; returns immediately on release.
private struct FORMPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PageRule: View {
    var opacity: Double = 0.4
    var body: some View {
        Rectangle()
            .fill(NativePalette.rule.opacity(opacity))
            .frame(height: 0.5)
    }
}

private struct PageLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(NativePalette.faint)
            .tracking(2.0)
    }
}

// ── Session detail sheet data ─────────────────────────────────────────────────
private struct SessionDetail {
    let session: String
    let purpose: String
    let execution: String
    let errors: [String]
    let notes: String
}

private let sessionDetails: [String: SessionDetail] = [
    "Z2 cross-train or rest": SessionDetail(
        session: "Z2 Cross-Train or Rest",
        purpose: "Absorb the previous week. Let the body consolidate.",
        execution: "If moving, keep effort genuinely easy — conversational, no strain. Bike, swim, walk. If tired, rest is the correct choice.",
        errors: ["Turning recovery into a workout", "Skipping because it feels too easy"],
        notes: "Structural work is appropriate here. Keep it brief and low-fatigue."
    ),
    "Threshold": SessionDetail(
        session: "Threshold",
        purpose: "Extend comfortable discomfort. Build the ceiling.",
        execution: "Start controlled. Each rep should feel like you could do one more. Last rep same quality as the first. Float is recovery, not rest — keep moving.",
        errors: ["Starting too fast on rep one", "Racing teammates", "Letting floats collapse into walking"],
        notes: "Heat: shorten floats or reduce rep count. Hills: effort stays constant, pace adjusts."
    ),
    "Easy Run": SessionDetail(
        session: "Easy Run",
        purpose: "Build aerobic base without adding fatigue.",
        execution: "Conversational pace throughout. No surges, no drifting moderate. If you can't speak in full sentences, you're too fast.",
        errors: ["Drifting into moderate effort", "Cutting short because it feels slow"],
        notes: "This is where the aerobic base is built. Easy is not optional."
    ),
    "Easy + Touch": SessionDetail(
        session: "Easy + Touch",
        purpose: "Maintain neuromuscular engagement with minimal fatigue.",
        execution: "45 minutes easy, then 6 × 200m relaxed at the end. The 200s should feel like you're waking up the legs, not racing. Smooth, not straining.",
        errors: ["Turning the 200s into a time trial", "Skipping the 200s when tired"],
        notes: "This session prepares coordination for the week without adding load."
    ),
    "Flush": SessionDetail(
        session: "Flush",
        purpose: "Clear metabolic byproducts. Arrive Saturday fresh.",
        execution: "Easy throughout. Shorter than normal if legs feel heavy. The goal is circulation and looseness, not fitness.",
        errors: ["Going too long", "Adding any intensity"],
        notes: "If you feel genuinely tired, cut this to 30 minutes or rest."
    ),
    "Long Run": SessionDetail(
        session: "Long Run",
        purpose: "Build endurance and economy at sustained effort.",
        execution: "Start easy, build through the middle, finish organized — not depleted. Effort leads. Duration supports. You should be able to run another 20 minutes at the end.",
        errors: ["Starting too fast", "Turning the middle into tempo effort", "Finishing ragged"],
        notes: "Fuel during the run. This is a training variable, not an afterthought."
    ),
    "Easy": SessionDetail(
        session: "Easy",
        purpose: "Absorb the week. Let the body integrate what it learned.",
        execution: "Short, genuinely easy. Legs should feel lighter by the end than the start. No pressure.",
        errors: ["Making it longer than needed", "Using it to make up for missed work"],
        notes: "This is the closing breath of the week. Protect it."
    ),
]

// ── WeekRow — one grammar for all seven rows ──────────────────────────────
//
// Today row treatment (typographic means only, no color/icon/fill):
//   · rule opacity up from 0.38 → 0.65 — slightly more present edge
//   · day label: tracking wider, weight medium, color secondary not faint
//   · session name: +1pt size, titleInk not bodyInk
//   · "today" mark: 8pt light small-caps below the detail, faint — discovered not announced
//
// Primary sessions (Threshold, Long Run): +2pt vertical padding above/below.
// Spacing alone signals priority. No structural change to the row.
private struct WeekRow: View {
    let day:     String
    let session: String
    let detail:  String
    let isToday: Bool

    @State private var showDetail  = false

    private var isPrimary: Bool {
        session.contains("Threshold") || session.contains("Long Run")
    }

    // Explicit switch — no partial matching. Each session string maps to exactly one key.
    private var sessionDetail: SessionDetail? {
        switch session {
        case "Z2 cross-train or rest": return sessionDetails["Z2 cross-train or rest"]
        case "Threshold":              return sessionDetails["Threshold"]
        case "Easy Run":               return sessionDetails["Easy Run"]
        case "Easy + Touch":           return sessionDetails["Easy + Touch"]
        case "Flush":                  return sessionDetails["Flush"]
        case "Long Run":               return sessionDetails["Long Run"]
        case "Easy":                   return sessionDetails["Easy"]
        default:                       return nil
        }
    }

    var body: some View {
        Button(action: { if sessionDetail != nil { showDetail = true } }) {
            VStack(alignment: .leading, spacing: 0) {
                PageRule(opacity: isToday ? 0.65 : 0.38)

                HStack(alignment: .firstTextBaseline, spacing: 0) {

                    // Day label — same position every row; tone and weight shift for today
                    Text(day)
                        .font(.system(size: 11,
                                      weight: isToday ? .medium : .regular))
                        .foregroundColor(isToday ? NativePalette.secondary : NativePalette.faint.opacity(0.88))
                        .tracking(isToday ? 0.7 : 0.4)
                        .frame(width: 48, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(session)
                            .font(.system(size: isToday ? 18 : 17, weight: isToday ? .semibold : .medium))
                            .foregroundColor(isToday ? NativePalette.titleInk : NativePalette.bodyInk)

                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary.opacity(0.72))
                        }
                    }
                    .padding(.top,    isPrimary ? 20 : 18)
                    .padding(.bottom, isPrimary ? 20 : 18)

                    Spacer()

                    if sessionDetail != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .light))
                            .foregroundColor(NativePalette.faint)
                            .padding(.leading, 8)
                    }
                }

                // Today row gets a closing rule too — frames the row, not just opens it
                if isToday {
                    PageRule(opacity: 0.65)
                }
            }
            // Full-width tap target
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Press feedback: very slight opacity dip
        }
        .buttonStyle(FORMPressStyle())
        .sheet(isPresented: $showDetail) {
            if let d = sessionDetail {
                SessionDetailSheet(detail: d)
            }
        }
    }
}

// ── Session detail sheet ──────────────────────────────────────────────────────
private struct SessionDetailSheet: View {
    let detail: SessionDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.formCream.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    // Header
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.formInkFaint)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {

                        Text(detail.session)
                            .font(.custom("Georgia", size: 28))
                            .foregroundColor(Color.nativeTitleInk)
                            .tracking(0.2)
                            .padding(.top, 16)
                            .padding(.bottom, 24)

                        // Purpose
                        sheetSection(label: "Purpose", body: detail.purpose)

                        // Execution
                        sheetSection(label: "Execution", body: detail.execution)

                        // Common errors
                        if !detail.errors.isEmpty {
                            Rectangle()
                                .fill(Color.nativeRule.opacity(0.35))
                                .frame(height: 0.5)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("COMMON ERRORS")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color.nativeFaint)
                                    .tracking(1.6)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(detail.errors, id: \.self) { error in
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Rectangle()
                                                .fill(Color.nativeFaint.opacity(0.4))
                                                .frame(width: 12, height: 0.75)
                                                .padding(.top, 8)
                                            Text(error)
                                                .font(.system(size: 15, weight: .regular))
                                                .foregroundColor(Color.nativeBodyInk.opacity(0.82))
                                                .lineSpacing(4)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 20)
                            .padding(.bottom, 24)
                        }

                        // Notes
                        if !detail.notes.isEmpty {
                            sheetSection(label: "Notes", body: detail.notes)
                        }

                        Spacer(minLength: 48)
                    }
                    .padding(.horizontal, 26)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sheetSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.nativeRule.opacity(0.35))
                .frame(height: 0.5)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.nativeFaint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(Color.nativeBodyInk.opacity(0.82))
                    .lineSpacing(5)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — FORMReadingFrame
//
// Page chassis for all native FORM pages.
//
// Owns:
//   · scroll behavior (no indicators)
//   · horizontal margins (22pt each side)
//   · maximum readable width (device width − 44, capped at 680pt)
//   · cream background
//   · centered reading column within the screen field
//
// Usage:
//   FORMReadingFrame { pageHeader; pageBody; closingDoctrine }
//
// All three native pages — Practice, Threshold, Long Run — and every future
// native page must start with FORMReadingFrame, never a raw ScrollView.
// This ensures margins, reading measure, scroll behavior, and background
// remain identical across the whole app without copy-pasting.
//
// iPad / large device behavior:
//   The 680pt cap means wide devices render a centered reading column,
//   exactly like Apple Books. No per-page changes required later.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMReadingFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                // Readable measure: fill the device minus margins, capped at 680pt.
                // On iPhone this resolves near full width; on iPad it creates a
                // centered reading column automatically.
                .frame(
                    maxWidth: min(geo.size.width - 52, 680),
                    alignment: .leading
                )
                .padding(.horizontal, 26)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.nativeCream.ignoresSafeArea())
    }
}

// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Practice chapter routing
//
// Practice chapter is a container. The weekly ledger is the root.
// Seven sub-pages are accessible via drawer or future in-page links.
// Local state drives routing — no shell navigation involved.
// Back rail returns from any sub-page to the ledger.
// ─────────────────────────────────────────────────────────────────────────────

enum PracticePage: String, CaseIterable {
    case method        = "Method"
    case plan          = "Plan"
    case strength      = "Strength"
    case cycles        = "Cycles"
    case theWork       = "The Work"
    case interruptions = "Interruptions"
    case theField      = "The Field"

    var descriptor: String {
        switch self {
        case .method:        return "The approach and its principles."
        case .plan:          return "How the week and arc are organized."
        case .strength:      return "What supports the running."
        case .cycles:        return "How progression works over time."
        case .theWork:       return "What we are actually practicing."
        case .interruptions: return "What breaks the system and what to do."
        case .theField:      return "The environment this method lives in."
        }
    }
}

enum ReferencePage: String, CaseIterable {
    case recovery = "Recovery"
    case fueling  = "Fueling"
    case sleep    = "Sleep"
    case pacing   = "Pacing"

    var descriptor: String {
        switch self {
        case .recovery: return "How the body actually absorbs the work between hard efforts."
        case .fueling:  return "How energy timing shapes session quality and long-term durability."
        case .sleep:    return "Why sleep is the most overlooked performance tool in the system."
        case .pacing:   return "How restraint and rhythm decide what speed you can actually hold."
        }
    }
}

struct FORMPracticeNativeView: View {
    @EnvironmentObject private var nativeNav: NativeNavStore
    @EnvironmentObject private var shell:     FORMShellStore
    @State private var selectedPage: PracticePage? = nil

    var body: some View {
        Group {
            if let page = selectedPage {
                PracticeSubPageView(page: page, onBack: {
                    selectedPage = nil
                    nativeNav.clearPractice()
                })
            } else {
                FORMPracticeLedgerView()
            }
        }
        // Respond to drawer sub-page intents
        .onChange(of: nativeNav.practicePage) { _, page in
            DispatchQueue.main.async { selectedPage = page }
        }
        // Reset to ledger whenever user leaves this chapter via spine or drawer
        .onChange(of: shell.selected) { _, dest in
            if dest != .home {
                DispatchQueue.main.async {
                    selectedPage = nil
                    nativeNav.clearPractice()
                }
            }
        }
    }
}

// Sub-page back rail + dispatcher — mirrors ReferenceSubPageView pattern
private struct PracticeSubPageView: View {
    let page:   PracticePage
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .regular))
                        Text("Practice")
                            .font(.system(size: 12, weight: .light))
                    }
                    .foregroundColor(.formInkFaint)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 26)
            .frame(height: 36)

            Rectangle()
                .fill(Color.formLine.opacity(0.35))
                .frame(height: 0.5)

            switch page {
            case .method:        FORMMethodNativeView()
            case .plan:          FORMPlanNativeView()
            case .strength:      FORMStrengthNativeView()
            case .cycles:        FORMCyclesNativeView()
            case .theWork:       FORMTheWorkNativeView()
            case .interruptions: FORMInterruptionsNativeView()
            case .theField:      FORMTheFieldNativeView()
            }
        }
        .background(Color.nativeCream.ignoresSafeArea())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Practice weekly ledger (formerly FORMPracticeNativeView)
// ─────────────────────────────────────────────────────────────────────────────

private struct FORMPracticeLedgerView: View {

    private let cycleLabel   = "Spring Cycle 2026 · Compression"
    private let phaseLabel   = "Durability · Rhythm · Economy"
    private let standard     = "Stay in the room."
    private let executionCue = "Neutral finishes. Leave 15% unused."

    private static var todayIndex: Int {
        (Calendar.current.component(.weekday, from: Date()) + 5) % 7
    }

    private var week: [(day: String, session: String, detail: String, isToday: Bool)] {
        let t = Self.todayIndex
        return [
            ("Mon", "Z2 cross-train or rest",  "+ structural work",                     t == 0),
            ("Tue", "Threshold",               "Controlled discomfort, extended.",      t == 1),
            ("Wed", "Easy Run",                "45 min · easy pace throughout",         t == 2),
            ("Thu", "Easy + Touch",            "45 min · 6 × 200 relaxed at end",      t == 3),
            ("Fri", "Flush",                   "45 min · easy · prepare for Saturday",  t == 4),
            ("Sat", "Long Run",                "Organization over impatience.",        t == 5),
            ("Sun", "Easy",                    "40 min · absorb the week",             t == 6),
        ]
    }

    var body: some View {
        FORMReadingFrame {
            pageHeader
            weekBlock
            closingNote
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {

            Text(cycleLabel.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Text("Practice")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 11)

            Text("The week, organized.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.82))
                .tracking(0.3)
                .padding(.bottom, 36)

            PageRule(opacity: 0.42)
        }
    }

    private var weekBlock: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .firstTextBaseline) {
                PageLabel(text: "Current week")
                Spacer()
                Text(phaseLabel.uppercased())
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.2)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            ForEach(week, id: \.day) { row in
                WeekRow(
                    day:     row.day,
                    session: row.session,
                    detail:  row.detail,
                    isToday: row.isToday
                )
            }

            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    private var closingNote: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)

            Text(standard)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)

            Text(executionCue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)

            PageRule(opacity: 0.35)
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Root content view
// ─────────────────────────────────────────────────────────────────────────────

struct ContentView: View {
    @StateObject private var shell      = FORMShellStore()
    @StateObject private var marksStore = FieldMarksStore()
    @StateObject private var nativeNav  = NativeNavStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingDrawer = false
    @State private var showingMarks  = false

    private var resolvedMarkTitle: String {
        resolveMarkTitle(
            pageTitle:    shell.activeTitle,
            sectionLabel: shell.selected.label,
            url:          shell.activeURL
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top frame ─────────────────────────────────────────────────
            FORMTopFrame(
                canGoBack: shell.activeCanGoBack,
                label:     shell.topFrameLabel,
                onBack:    { shell.goBack() },
                onIndex:   { showingDrawer = true }
            )

            // ── Content area ──────────────────────────────────────────────
            // Home      → FORMPracticeNativeView
            // Threshold → FORMThresholdNativeView
            // Long Run  → FORMLongRunNativeView
            // Reference → FORMReferenceNativeView (index + editorial pages)
            // Athletes  → webview (permanent)
            ZStack {
                // ── Native pages ──────────────────────────────────────────
                FORMPracticeNativeView()
                    .opacity(shell.selected == .home ? 1 : 0)
                    .allowsHitTesting(shell.selected == .home)
                    .environmentObject(nativeNav)
                    .environmentObject(shell)

                FORMThresholdNativeView()
                    .opacity(shell.selected == .threshold ? 1 : 0)
                    .allowsHitTesting(shell.selected == .threshold)

                FORMLongRunNativeView()
                    .opacity(shell.selected == .longRun ? 1 : 0)
                    .allowsHitTesting(shell.selected == .longRun)

                FORMReferenceNativeView()
                    .opacity(shell.selected == .reference ? 1 : 0)
                    .allowsHitTesting(shell.selected == .reference)
                    .environmentObject(nativeNav)
                    .environmentObject(shell)

                // ── Webview chapters (Athletes only) ─────────────────────
                ForEach(FORMDestination.allCases.filter {
                    $0 != .home && $0 != .threshold && $0 != .longRun && $0 != .reference
                }) { dest in
                    if shell.initializedChapters.contains(dest) {
                        FORMSectionView(destination: dest, shell: shell)
                            .opacity(shell.selected == dest ? 1 : 0)
                            .allowsHitTesting(shell.selected == dest)
                    } else {
                        Color.formCream
                            .opacity(0)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ── Chapter swipe — deliberate horizontal-only, root-only ─────────────
            // minimumDistance 48 ensures vertical scroll always wins.
            // 2:1 axis ratio check prevents diagonal misfires.
            // Disabled when webview can go back (mid-article) to avoid conflict.
            .gesture(
                DragGesture(minimumDistance: 48, coordinateSpace: .local)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 2 else { return }
                        if shell.activeCanGoBack { return }
                        let all = FORMDestination.allCases
                        guard let idx = all.firstIndex(of: shell.selected) else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if dx < 0, idx < all.count - 1 {
                                let next = all[all.index(after: idx)]
                                nativeNav.resetToRoot(for: next)
                                shell.selectChapter(next)
                            } else if dx > 0, idx > all.startIndex {
                                let prev = all[all.index(before: idx)]
                                nativeNav.resetToRoot(for: prev)
                                shell.selectChapter(prev)
                            }
                        }
                    }
            )

            // ── Bottom spine ──────────────────────────────────────────────
            FORMBottomSpine(shell: shell, nativeNav: nativeNav)
        }
        .background(Color.formCream)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = (scenePhase == .active)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = (phase == .active)
        }
        .sheet(isPresented: $showingDrawer) {
            FORMDrawer(
                shell:        shell,
                nativeNav:    nativeNav,
                onNavigate:   { dest, url in shell.navigate(to: dest, url: url) },
                onShowMarks:  { showingMarks = true },
                onToggleMark: {
                    guard !shell.activeURL.isEmpty else { return }
                    marksStore.toggle(
                        title:       resolvedMarkTitle,
                        destination: shell.selected,
                        url:         shell.activeURL
                    )
                }
            )
            .environmentObject(marksStore)
        }
        .sheet(isPresented: $showingMarks) {
            FieldMarksSheet { dest, url in shell.navigate(to: dest, url: url) }
                .environmentObject(marksStore)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — FORMStepBlock
//
// Shared step component for all session and run pages.
//
// Anatomy (vertical, not horizontal):
//   top rule
//   step label     — small, faint, structural (step name only)
//   primary line   — the action; must be readable across the room
//   support line   — optional; shorter, quieter, interpretive
//
// Law: action is visible before explanation.
// Ranked information hierarchy. Three levels only:
//
//   PRIMARY   — numeric / structural (what you see from across the room)
//   SECONDARY — what the block is (label, effort type)
//   TERTIARY  — explanatory / qualifying (optional, smallest)
//
// The number leads. The label follows. The explanation is tertiary.
//
// Anatomy (top to bottom):
//   top rule
//   number     — Georgia, large, titleInk  ← eye lands here first
//   label      — system small-caps, faint  ← names the block
//   qualifier  — Georgia small, secondary  ← optional, supports the number
//
// Rank variants:
//   .support — setup and exit blocks (Warm-up, Cool-down, Opening, Close)
//   .normal  — standard blocks
//   .main    — dominant event (Main set, Middle) — number is noticeably larger
//
// Test: squint at the page. You should see the numbers before reading any words.
// ─────────────────────────────────────────────────────────────────────────────

private enum StepRank   { case support, subordinate, normal, main }

// StepLayout controls which element reads first.
//
//   structureLead — number primary, label secondary (Threshold: "3 × 10 min / THRESHOLD")
//   effortLead    — label primary, number secondary (Long Run:  "Easy / 45 min")
//
// All other behavior — rank sizing, spacing, rule opacity, qualifier — is identical.
// One component. Two cognitive tasks.
private enum StepLayout { case structureLead, effortLead }

// ── Step detail data ──────────────────────────────────────────────────────────
private struct StepDetail {
    let title:     String
    let purpose:   String
    let execution: String
    let notes:     String
}

private let stepDetails: [String: StepDetail] = [
    "Warm-up": StepDetail(
        title: "Warm-Up",
        purpose: "Prepare the body for threshold effort. Raise core temperature, mobilize the joints, wake up the fast-twitch fibers.",
        execution: "15 minutes total: first 12 minutes easy and conversational, final 3 minutes a gradual build toward threshold — arrive ready, not rushed.",
        notes: "If the legs feel flat or heavy, stay patient and let the warm-up do its work. Avoid adding extra speed or drills that turn this into its own workout."
    ),
    "Threshold": StepDetail(
        title: "Threshold",
        purpose: "Extend the duration you can sustain at high aerobic effort. This is the ceiling-raising work.",
        execution: "3 × 10 minutes at controlled discomfort — breathing working, posture calm, last rep the same quality as the first.",
        notes: "If you could not imagine running a fourth rep at the end, the effort was too high. Treat threshold as repeatable work, not a race effort, and let the floats do their job."
    ),
    "Float": StepDetail(
        title: "Float",
        purpose: "Active recovery between threshold reps. Flush, regroup, maintain forward momentum.",
        execution: "2 minutes of very easy running between reps — keep moving forward while breathing returns toward conversational.",
        notes: "If you need more than 2 minutes to restore quality, adjust the prior rep instead of stretching the float. The standard is starting each rep composed, not desperate."
    ),
    "Cool-down": StepDetail(
        title: "Cool-Down",
        purpose: "Return the body to baseline. Start the recovery process.",
        execution: "10 minutes of genuinely easy running — heart rate coming down, breathing settling, no rushing.",
        notes: "Treat the cool-down as part of the work, not an optional extra. Stopping early or standing around stiffens what the run just organized."
    ),
    "Easy": StepDetail(
        title: "Easy",
        purpose: "Settle the run. Let the body find its rhythm before asking more of it.",
        execution: "First 25 minutes truly easy — relaxed shoulders, light feet, let the pace come to you.",
        notes: "If you feel impatient here, you're doing it correctly. This section protects the rest of the run from starting too fast."
    ),
    "Steady": StepDetail(
        title: "Steady",
        purpose: "Hold sustained aerobic effort. Train the body to maintain quality over time.",
        execution: "Middle 45 minutes at steady aerobic effort — breathing present but smooth, rhythm locked in, no surges.",
        notes: "If you cannot speak a full sentence, you have drifted too hard. Small terrain-driven pace changes are fine; big swings are not."
    ),
    "Close": StepDetail(
        title: "Close",
        purpose: "Finish organized, not depleted. Leave the run strong.",
        execution: "Final 25 minutes at the same steady effort, letting focus sharpen while form stays identical.",
        notes: "You should finish feeling organized with one small gear still available. If you are hanging on, the middle section was too hard."
    ),
]

// ── Session Mode data ───────────────────────────────────────────────────────────

private struct SessionModeBlock {
    let label:     String
    let structure: String
    let cue:       String
}

private struct SessionModeSession {
    let title:      String
    let anchorLine: String
    let blocks:     [SessionModeBlock]
}

private let thresholdSession = SessionModeSession(
    title:      "Threshold",
    anchorLine: "Controlled discomfort, extended.",
    blocks: [
        SessionModeBlock(label: "Warm-up",  structure: "15 min easy",           cue: "final 3 min build"),
        SessionModeBlock(label: "Main Set", structure: "3 × 10 min threshold",  cue: "2 min float between reps"),
        SessionModeBlock(label: "Cool-down",structure: "10 min easy",           cue: "let the system settle"),
    ]
)

private let longRunSession = SessionModeSession(
    title:      "Long Run",
    anchorLine: "Organization over impatience.",
    blocks: [
        SessionModeBlock(label: "Opening", structure: "25 min easy",   cue: "start calm · let the pace come to you"),
        SessionModeBlock(label: "Middle",  structure: "45 min steady", cue: "hold rhythm · smooth cadence throughout"),
        SessionModeBlock(label: "Close",   structure: "25 min",        cue: "finish organized · maintain form under fatigue"),
    ]
)


private struct FORMStepBlock: View {
    let number:    String
    let label:     String
    let qualifier: String
    var rank:      StepRank   = .normal
    var layout:    StepLayout = .structureLead

    @State private var showDetail = false

    private var stepDetail: StepDetail? {
        stepDetails[label]
    }

    private var primarySize: CGFloat {
        switch rank {
        case .support:     return 22
        case .subordinate: return 20
        case .normal:      return 23
        case .main:        return 29
        }
    }

    private var topPad: CGFloat {
        switch rank {
        case .subordinate: return 10
        case .support:     return 14
        case .normal:      return 17
        case .main:        return 17
        }
    }

    private var bottomPad: CGFloat {
        switch rank {
        case .subordinate: return 10
        case .support:     return 14
        case .normal:      return 18
        case .main:        return 19
        }
    }

    private var ruleOpacity: Double {
        switch rank {
        case .main:        return 0.50
        case .subordinate: return 0.28
        default:           return 0.35
        }
    }

    var body: some View {
        Button(action: { if stepDetail != nil { showDetail = true } }) {
            VStack(alignment: .leading, spacing: 0) {
                PageRule(opacity: ruleOpacity)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        switch layout {

                        // ── structureLead: number → label → qualifier ────────────
                        case .structureLead:
                            Text(number)
                                .font(.system(size: primarySize, weight: .regular).monospacedDigit())
                                .foregroundColor(NativePalette.titleInk)
                                .padding(.bottom, 5)

                            Text(label.uppercased())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(NativePalette.secondary.opacity(0.72))
                                .tracking(1.4)
                                .padding(.bottom, qualifier.isEmpty ? 0 : 5)

                        // ── effortLead: "Effort · duration" inline, qualifier below ──
                        // Long Run. Glance reads: Easy · 25 min / Steady · 45 min / Close · 25 min.
                        // Effort word leads with weight. Duration attached with mid-dot, lighter.
                        // Qualifier drops below as tertiary cue.
                        case .effortLead:
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(label)
                                    .font(.system(size: primarySize, weight: .medium))
                                    .foregroundColor(NativePalette.titleInk)
                                Text(" · ")
                                    .font(.system(size: primarySize - 4, weight: .light))
                                    .foregroundColor(NativePalette.faint)
                                Text(number)
                                    .font(.system(size: primarySize - 4, weight: .regular).monospacedDigit())
                                    .foregroundColor(NativePalette.secondary)
                            }
                            .padding(.bottom, qualifier.isEmpty ? 0 : 5)
                        }

                        // Qualifier — identical behavior in both layouts
                        if !qualifier.isEmpty {
                            Text(qualifier)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary.opacity(0.85))
                                .tracking(0.15)
                        }
                    }
                    .padding(.top, topPad)
                    .padding(.bottom, bottomPad)

                    Spacer()

                    if stepDetail != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .light))
                            .foregroundColor(NativePalette.faint)
                            .padding(.top, topPad + 6)
                    }
                }
            }
            // Full-width tap target
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Press feedback: subtle opacity dip
        }
        .buttonStyle(FORMPressStyle())
        .sheet(isPresented: $showDetail) {
            if let d = stepDetail {
                StepDetailSheet(detail: d)
            }
        }
    }
}

// ── Session Mode full-screen card ───────────────────────────────────────────────

private struct SessionModeView: View {
    let session:   SessionModeSession
    let isLongRun: Bool

    @State private var activeRep: Int = 1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.nativeCream.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {

                // Header
                HStack {
                    Button("Done") { dismiss() }
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.formInkFaint)
                    Spacer()
                }
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 0) {
                    Text(session.title)
                        .font(.custom("Georgia", size: 36))
                        .foregroundColor(Color.nativeTitleInk)
                        .tracking(0.2)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    Text(session.anchorLine)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(Color.nativeSecondary.opacity(0.88))
                        .tracking(0.2)
                        .padding(.bottom, 24)

                    PageRule(opacity: 0.42)

                    // Blocks
                    ZStack(alignment: .leading) {
                        if isLongRun {
                            HStack(alignment: .top, spacing: 0) {
                                Rectangle()
                                    .fill(Color.nativeRule.opacity(0.5))
                                    .frame(width: 1)
                                    .padding(.top, 36)
                                    .padding(.bottom, 20)
                                    .padding(.leading, 2)
                                Spacer()
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(session.blocks.enumerated()), id: \.offset) { index, block in
                                blockView(block: block, isFirst: index == 0)
                            }

                            PageRule(opacity: 0.35)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 26)
            }
        }
    }

    @ViewBuilder
    private func blockView(block: SessionModeBlock, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.35)
                .padding(.top, isFirst ? 24 : 18)

            VStack(alignment: .leading, spacing: 6) {
                Text(block.label.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.nativeFaint)
                    .tracking(1.4)

                Text(block.structure)
                    .font(.system(size: 26, weight: .regular).monospacedDigit())
                    .foregroundColor(Color.nativeTitleInk)

                Text(block.cue)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color.nativeSecondary.opacity(0.85))
                    .tracking(0.1)

                if session.title == "Threshold" && block.label == "Main Set" {
                    HStack(spacing: 0) {
                        ForEach(1...3, id: \.self) { rep in
                            Button(action: { activeRep = rep }) {
                                Text("Rep \(rep)")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(
                                        rep == activeRep
                                        ? Color.nativeBodyInk
                                        : Color.nativeFaint
                                    )
                            }
                            .buttonStyle(.plain)

                            if rep < 3 {
                                Text(" · ")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(Color.nativeFaint)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
    }
}

// ── Step detail sheet ─────────────────────────────────────────────────────────
private struct StepDetailSheet: View {
    let detail: StepDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.formCream.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .font(.system(size: 12, weight: .light))
                            .foregroundColor(.formInkFaint)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 0) {

                        Text(detail.title)
                            .font(.custom("Georgia", size: 28))
                            .foregroundColor(Color.nativeTitleInk)
                            .tracking(0.2)
                            .padding(.top, 16)
                            .padding(.bottom, 24)

                        stepSheetSection(label: "Purpose",   body: detail.purpose)
                        stepSheetSection(label: "Execution", body: detail.execution)

                        if !detail.notes.isEmpty {
                            stepSheetSection(label: "Notes", body: detail.notes)
                        }

                        Spacer(minLength: 48)
                    }
                    .padding(.horizontal, 26)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func stepSheetSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.nativeRule.opacity(0.35))
                .frame(height: 0.5)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.nativeFaint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(Color.nativeBodyInk.opacity(0.82))
                    .lineSpacing(5)
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native palette alias (file-scope)
//
// Renamed from NP → NativePalette for clarity.
// Source of truth remains Color extension (nativeTitleInk etc.).
// ─────────────────────────────────────────────────────────────────────────────

private enum NativePalette {
    static let titleInk  = Color.nativeTitleInk
    static let bodyInk   = Color.nativeBodyInk
    static let secondary = Color.nativeSecondary
    static let faint     = Color.nativeFaint
    static let rule      = Color.nativeRule
    static let cream     = Color.nativeCream
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Threshold page
//
// Session brief. Ranked information — numbers lead, labels follow.
// Glance test: 15 min / 3×10 min / 2 min / 10 min readable before any words.
// Main set is the page's center of gravity.
// Float is support, not equal chapter.
// Cues removed — doctrine carries the closing.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMThresholdNativeView: View {

    private let cycleLabel = "Spring Cycle 2026 · Compression"
    private let anchorLine = "Controlled discomfort, extended."
    private let doctrine   = "The effort is the practice."
    private let cue        = "Stay under theatrics. Finish the rep, not the clock."

    @State private var showingSessionCard = false
    @State private var didTapTitle        = false

    var body: some View {
        FORMReadingFrame {
            pageHeader
            stepsBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
        .fullScreenCover(isPresented: $showingSessionCard) {
            SessionModeView(session: thresholdSession, isLongRun: false)
        }
    }

    // ── Page header ──────────────────────────────────────────────────────────

    private var pageHeader: some View {
        Button(action: { didTapTitle = true }) {
            VStack(alignment: .leading, spacing: 0) {

                Text(cycleLabel.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.4)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                Text("Threshold")
                    .font(.custom("Georgia", size: 36))
                    .foregroundColor(NativePalette.titleInk)
                    .tracking(0.2)
                    .padding(.bottom, 8)

                Text(anchorLine)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(NativePalette.secondary.opacity(0.88))
                    .tracking(0.2)
                    .padding(.bottom, 36)

                PageRule(opacity: 0.42)
            }
        }
        .buttonStyle(.plain)
    }

    // ── Session steps ────────────────────────────────────────────────────────
    // 15 min / 3×10 min / 2 min / 10 min — numbers readable before words.
    // Main set dominates. Float restored as subordinate — visible, not equal.
    // Labels stripped to single names. Qualifiers shortened to structural cues.

    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {

            PageLabel(text: "Tuesday · Session")
                .padding(.top, 20)
                .padding(.bottom, 4)

            Button(action: { showingSessionCard = true }) {
                Text("Open session card")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(NativePalette.faint.opacity(0.9))
                    .padding(.bottom, 8)
            }
            .buttonStyle(FORMPressStyle())

            FORMStepBlock(
                number:    "15 min",
                label:     "Warm-up",
                qualifier: "final 3 min build · arrive ready, not rushed",
                rank:      .support
            )
            FORMStepBlock(
                number:    "3 × 10 min",
                label:     "Threshold",
                qualifier: "controlled discomfort · same quality each rep",
                rank:      .main
            )
            FORMStepBlock(
                number:    "2 min",
                label:     "Float",
                qualifier: "conversational recovery · keep moving forward",
                rank:      .subordinate
            )
            FORMStepBlock(
                number:    "10 min",
                label:     "Cool-down",
                qualifier: "let the system settle",
                rank:      .support
            )

            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // ── Closing doctrine ─────────────────────────────────────────────────────

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)

            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)

            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)

            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Long Run page
//
// Field orientation. Effort progression, not interval structure.
// effortLead layout: glance reads Easy → Steady → Close.
// Mirrors how the mind tracks a run — effort state first, duration second.
// Doctrine at close.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMLongRunNativeView: View {

    private let cycleLabel = "Spring Cycle 2026 · Compression"
    private let anchorLine = "Organization over impatience."
    private let doctrine   = "Duration reveals form."
    private let cue        = "Inhabit the effort. Finish organized, not depleted."

    @State private var showingSessionCard = false
    @State private var didTapTitle        = false

    var body: some View {
        FORMReadingFrame {
            pageHeader
            runStructure
            closingDoctrine
            Spacer(minLength: 56)
        }
        .fullScreenCover(isPresented: $showingSessionCard) {
            SessionModeView(session: longRunSession, isLongRun: true)
        }
    }

    // ── Page header ──────────────────────────────────────────────────────────

    private var pageHeader: some View {
        Button(action: { didTapTitle = true }) {
            VStack(alignment: .leading, spacing: 0) {

                Text(cycleLabel.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.4)
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                Text("Long Run")
                    .font(.custom("Georgia", size: 36))
                    .foregroundColor(NativePalette.titleInk)
                    .tracking(0.2)
                    .padding(.bottom, 8)

                Text(anchorLine)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(NativePalette.secondary.opacity(0.88))
                    .tracking(0.2)
                    .padding(.bottom, 36)

                PageRule(opacity: 0.42)
            }
        }
        .buttonStyle(.plain)
    }

    // ── Run structure ────────────────────────────────────────────────────────
    // effortLead layout: effort word dominates, duration supports.
    // Glance reads: Easy → Steady → Close.
    // Mirrors how the mind tracks a run — by effort state, not elapsed time.

    private var runStructure: some View {
        VStack(alignment: .leading, spacing: 0) {

            PageLabel(text: "Saturday · 95 min")
                .padding(.top, 20)
                .padding(.bottom, 4)

            Button(action: { showingSessionCard = true }) {
                Text("Open session card")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(NativePalette.faint.opacity(0.9))
                    .padding(.bottom, 8)
            }
            .buttonStyle(FORMPressStyle())

            FORMStepBlock(
                number:    "25 min",
                label:     "Easy",
                qualifier: "start calm · let the pace come to you",
                rank:      .normal,
                layout:    .effortLead
            )
            FORMStepBlock(
                number:    "45 min",
                label:     "Steady",
                qualifier: "build rhythm · hold the effort without forcing",
                rank:      .normal,
                layout:    .effortLead
            )
            FORMStepBlock(
                number:    "25 min",
                label:     "Close",
                qualifier: "finish organized · same form, slightly less margin",
                rank:      .normal,
                layout:    .effortLead
            )

            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // ── Closing doctrine ─────────────────────────────────────────────────────

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)

            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)

            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)

            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Reference page (index grammar)
//
// Navigation surface, not editorial document.
// Job: show what lives in this section so the user can move quickly.
// Grammar: section title → descriptor → entry rows → optional doctrine.
//
// Entry rows are navigable lines, not cards.
// No chevrons, no backgrounds, no icons.
// Tappable area is the whole row.
//
// Sub-pages (Recovery, Fueling, Sleep, Pacing) are native editorial pages
// accessible from this index. They share FORMReadingFrame and native palette.
//
// State: selectedPage drives which sub-page is showing.
//        nil = index. non-nil = sub-page content.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMReferenceNativeView: View {

    @State private var selectedPage: ReferencePage? = nil

    @EnvironmentObject private var nativeNav: NativeNavStore
    @EnvironmentObject private var shell:     FORMShellStore

    var body: some View {
        Group {
            if let page = selectedPage {
                ReferenceSubPageView(page: page, onBack: {
                    selectedPage = nil
                    nativeNav.clearReference()
                })
            } else {
                referenceIndex
            }
        }
        .onChange(of: nativeNav.referencePage) { _, page in
            DispatchQueue.main.async { selectedPage = page }
        }
        // Reset to index whenever user leaves this chapter via spine or drawer
        .onChange(of: shell.selected) { _, dest in
            if dest != .reference {
                DispatchQueue.main.async {
                    selectedPage = nil
                    nativeNav.clearReference()
                }
            }
        }
    }

    // ── Reference index ──────────────────────────────────────────────────────

    private var referenceIndex: some View {
        FORMReadingFrame {
            indexHeader
            entryList
            Spacer(minLength: 56)
        }
    }

    private var indexHeader: some View {
        VStack(alignment: .leading, spacing: 0) {

            Text("Reference".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Text("Reference")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)

            Text("The supporting systems.")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)

            PageRule(opacity: 0.42)
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 0) {

            PageLabel(text: "In this section")
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(ReferencePage.allCases, id: \.self) { page in
                referenceEntryRow(page: page)
            }

            PageRule(opacity: 0.38)
        }
    }

    private func referenceEntryRow(page: ReferencePage) -> some View {
        PressableReferenceRow(page: page) {
            selectedPage = page
            nativeNav.navigate(to: page)
        }
    }
}

// Separate struct so @State can track press per-row
private struct PressableReferenceRow: View {
    let page:   ReferencePage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                PageRule(opacity: 0.32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.rawValue)
                        .font(.custom("Georgia", size: 21))
                        .foregroundColor(NativePalette.titleInk)
                        .tracking(0.2)
                    Text(page.descriptor)
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(NativePalette.secondary.opacity(0.82))
                        .tracking(0.1)
                }
                .padding(.top, 26)
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(FORMPressStyle())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Reference sub-page dispatcher
//
// Routes from the reference index to each individual editorial page.
// Each sub-page uses FORMReadingFrame and shares the same native grammar.
// Back returns to the Reference index.
// ─────────────────────────────────────────────────────────────────────────────

private struct ReferenceSubPageView: View {
    let page:   ReferencePage
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Local back rail — not the shell top frame
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .regular))
                        Text("Reference")
                            .font(.system(size: 12, weight: .light))
                    }
                    .foregroundColor(.formInkFaint)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 26)
            .frame(height: 36)

            Rectangle()
                .fill(Color.formLine.opacity(0.35))
                .frame(height: 0.5)

            switch page {
            case .recovery: FORMRecoveryNativeView()
            case .fueling:  FORMFuelingNativeView()
            case .sleep:    FORMSleepNativeView()
            case .pacing:   FORMPacingNativeView()
            }
        }
        .background(Color.nativeCream.ignoresSafeArea())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Recovery page (editorial grammar)
//
// Pure reading page. No numeric hierarchy. No step blocks.
// Job: answer what recovery is and what it requires, calmly and completely.
// Tone: quieter than the session pages. Durable, not sharp.
//
// Grammar: title → anchor → body sections → doctrine landing
// Body sections are prose blocks with a section label and one or two paragraphs.
// No cards, no bullets, no expandable sections.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMRecoveryNativeView: View {

    private let anchorLine = "The work happens here."

    private let sections: [(label: String, body: String)] = [
        (
            "What recovery is",
            "Recovery is not rest from training. It is training. The adaptation you seek — the speed, the economy, the strength — happens in the hours after the session, not during it. Without recovery, the session is only damage."
        ),
        (
            "The minimum",
            "Sleep is the first tool. Seven to nine hours. Not negotiable. Without it, the rest of recovery — nutrition, movement, stress management — works at reduced capacity. Sleep first, then everything else."
        ),
        (
            "Between sessions",
            "Easy days are not wasted days. They are days the body learns to be fast at lower cost. Protect them. Do not turn easy into moderate. The discipline of easy effort is equal to the discipline of hard effort."
        ),
        (
            "What depletes recovery",
            "Life stress and training stress draw from the same pool. A hard week at work costs something. Travel costs something. Poor sleep costs something. The body does not distinguish sources. It only knows load."
        ),
        (
            "The standard",
            "You should arrive at the next session ready. Not intact. Ready — which means able to do the work at full quality. If you cannot, recovery has not completed. Adjust before adding more."
        ),
    ]

    private let doctrine = "You cannot outwork a recovery deficit."
    private let cue      = "Rest is the other half of the method."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            bodyContent
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    // ── Page header ──────────────────────────────────────────────────────────

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {

            Text("Reference · Recovery".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Text("Recovery")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)

            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)

            PageRule(opacity: 0.42)
        }
    }

    // ── Body content ─────────────────────────────────────────────────────────
    // Editorial sections. Label names the idea. Prose carries it.
    // No numeric hierarchy. No step blocks. Reads top to bottom.

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.label) { section in
                editorialSection(label: section.label, body: section.body)
            }
        }
    }

    private func editorialSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(NativePalette.bodyInk.opacity(0.78))
                    .lineSpacing(7)
                    .tracking(0.08)
            }
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    // ── Closing doctrine ─────────────────────────────────────────────────────

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.38)
            Spacer().frame(height: 60)

            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)

            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)

            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Fueling page (editorial grammar)
// ─────────────────────────────────────────────────────────────────────────────

struct FORMFuelingNativeView: View {

    private let anchorLine = "Fuel the work you are actually doing."

    private let sections: [(label: String, body: String)] = [
        (
            "The basic principle",
            "Eat enough. Most athletes who are not recovering well are not sleeping enough or eating enough. Before looking for optimization, check the floor. Are you consistently fueled before, during, and after hard sessions?"
        ),
        (
            "Before the session",
            "Eat 2–3 hours before if possible. A real meal — not a supplement. Carbohydrate is the primary fuel for threshold and track work. Fat fuels easy effort well. Protein supports recovery but is not a primary training fuel."
        ),
        (
            "During the session",
            "For runs under 75 minutes at easy effort, most athletes do not need to fuel mid-run. For longer runs or harder sessions, carbohydrate during the session sustains quality and supports recovery. Practice your fueling strategy in training."
        ),
        (
            "After the session",
            "Eat within 30–60 minutes of finishing. Protein and carbohydrate together. This is not complicated. A meal works. A snack works. The goal is to start the recovery process before you make other decisions."
        ),
        (
            "The long arc",
            "Week-to-week energy availability matters more than per-session optimization. Chronically underfueled athletes cannot adapt at full speed regardless of session quality. Fueling is not a detail. It is a training variable."
        ),
    ]

    private let doctrine = "The body adapts to what it receives."
    private let cue      = "Fuel the training, not the fantasy version of it."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            bodyContent
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reference · Fueling".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Fueling")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.label) { section in
                editorialSection(label: section.label, body: section.body)
            }
        }
    }

    private func editorialSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(NativePalette.bodyInk.opacity(0.78))
                    .lineSpacing(7)
                    .tracking(0.08)
            }
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.38)
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Sleep page (editorial grammar)
// ─────────────────────────────────────────────────────────────────────────────

struct FORMSleepNativeView: View {

    private let anchorLine = "The most underused tool in the system."

    private let sections: [(label: String, body: String)] = [
        (
            "What sleep does",
            "During sleep the body releases growth hormone, consolidates motor patterns, repairs tissue, and clears metabolic byproducts from training. These processes cannot be meaningfully replicated while awake. Sleep is not passive downtime. It is active adaptation."
        ),
        (
            "The minimum",
            "Seven to nine hours. Consistently. Not average — consistent. One night of short sleep measurably reduces reaction time, coordination, and mood the following day. Several nights compounds the deficit. The body does not fully recover the debt over a single long night."
        ),
        (
            "Sleep and training load",
            "Higher training loads require more sleep, not less. This is the common error — increasing volume while tolerating poor sleep. The adaptation you are training for happens during sleep. Cutting sleep to fit in training is a contradiction."
        ),
        (
            "Practical standard",
            "Set a consistent sleep and wake time. Treat it as a training variable. Reduce evening light 60–90 minutes before sleep. Keep the room cool and dark. Limit alcohol — it fragments sleep architecture even when it helps you fall asleep faster."
        ),
    ]

    private let doctrine = "Sleep is where the speed is made."
    private let cue      = "Protect it with the same discipline as the hard session."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            bodyContent
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reference · Sleep".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Sleep")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.label) { section in
                editorialSection(label: section.label, body: section.body)
            }
        }
    }

    private func editorialSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(NativePalette.bodyInk.opacity(0.78))
                    .lineSpacing(7)
                    .tracking(0.08)
            }
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.38)
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Pacing page (editorial grammar)
// ─────────────────────────────────────────────────────────────────────────────

struct FORMPacingNativeView: View {

    private let anchorLine = "Effort sustained is faster than effort spent."

    private let sections: [(label: String, body: String)] = [
        (
            "The principle",
            "Pacing is not about going slow. It is about effort management across time. The fastest runners are not the ones who start fastest — they are the ones who hold the most of their capacity in reserve until it can be used. Going out too hard is not boldness. It is poor accounting."
        ),
        (
            "Easy effort",
            "Easy means a pace at which you could hold a full conversation without effort. Not slightly hard. Not comfortably hard. Genuinely easy. If it feels too slow, it is probably right. Easy effort builds aerobic infrastructure without accruing the fatigue cost of moderate effort."
        ),
        (
            "Threshold effort",
            "Threshold is the edge of controlled discomfort. You can sustain it, but not forever. You cannot hold a sentence at threshold. You can hold a word. This effort builds the capacity to hold race pace longer. It should feel demanding, not panicked."
        ),
        (
            "The middle ground",
            "Moderate effort — the zone between easy and threshold — is the most commonly overtrained zone. It is hard enough to cost recovery but not hard enough to build threshold capacity efficiently. Reduce time here. Make easy truly easy and hard truly hard."
        ),
        (
            "Finishing",
            "Finish with something left. This is not timidity. This is how adaptation compounds. The body adapts to a stimulus it survives well, not one it barely survives. Leave 10–15 percent on the table. That is the discipline."
        ),
    ]

    private let doctrine = "The finish line is the test of every earlier decision."
    private let cue      = "What you hold in reserve is what you arrive with."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            bodyContent
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reference · Pacing".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Pacing")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections, id: \.label) { section in
                editorialSection(label: section.label, body: section.body)
            }
        }
    }

    private func editorialSection(label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.35)
            VStack(alignment: .leading, spacing: 10) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NativePalette.faint)
                    .tracking(1.6)
                Text(body)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(NativePalette.bodyInk.opacity(0.78))
                    .lineSpacing(7)
                    .tracking(0.08)
            }
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.38)
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Method page (hybrid: doctrine-organized, scan-ready)
//
// Sits between editorial and structure.
// Reads like doctrine. Organized enough to scan.
// Each principle is a distinct block: label names it, prose carries it.
// No step-block numeric hierarchy — this is not session structure.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMMethodNativeView: View {

    private let anchorLine = "The approach and why it holds."

    private let principles: [(label: String, body: String)] = [
        (
            "Consistency before intensity",
            "The method begins with showing up. Not perfectly — consistently. A reliable 80% is more productive over a season than a brilliant 100% followed by an injury or a missed month. The system compounds what it can hold."
        ),
        (
            "Aerobic base first",
            "Most of the work is easy. That is not a limitation — it is the architecture. Easy running builds the aerobic infrastructure that hard sessions run on. Without the base, threshold work is borrowed against a debt you cannot pay."
        ),
        (
            "Structure over motivation",
            "Motivation is a feeling and feelings change. Structure is a decision made in advance. The plan exists so that on the hard days you don't have to decide — you just have to follow. The session happens because it is scheduled, not because you feel like running."
        ),
        (
            "Effort is honest",
            "You cannot fake fitness. The body knows what it has built and what it hasn't. The method asks you to work at the effort that matches your current capacity, not the one you want to have. Threshold on a bad day is still threshold. Easy is still easy."
        ),
        (
            "Recovery is training",
            "Sleep, nutrition, rest between sessions — these are not rewards for hard work. They are the mechanism by which hard work becomes adaptation. A session without adequate recovery is only damage. Recovery is where the session pays off."
        ),
        (
            "One cycle at a time",
            "Each training cycle has a purpose. Durability. Economy. Sharpening. Competing. You cannot build all qualities simultaneously at full intensity. The method chooses one priority per cycle and builds around it. Trust the sequence."
        ),
    ]

    private let doctrine = "The method is not a shortcut. It is the way."
    private let cue      = "Follow it for long enough to find out what it builds."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            principlesBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Method".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Method")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    private var principlesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(principles, id: \.label) { p in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.35)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(p.label.uppercased())
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(NativePalette.faint)
                            .tracking(1.6)
                        Text(p.body)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(NativePalette.bodyInk)
                            .lineSpacing(6)
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 26)
                }
            }
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageRule(opacity: 0.38)
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Plan page (index / structure grammar)
//
// How the week and training arc are organized.
// Scan-first: the week structure must be legible before reading detail.
// Two surfaces: weekly structure (session type per day) + arc overview (phases).
// ─────────────────────────────────────────────────────────────────────────────

struct FORMPlanNativeView: View {

    private let anchorLine = "The week has a shape. So does the season."

    private let weekStructure: [(day: String, type: String, note: String)] = [
        ("Mon", "Cross / Rest",  "structural work if available"),
        ("Tue", "Threshold",     "primary session of the week"),
        ("Wed", "Easy",          "45 min · recovery pace throughout"),
        ("Thu", "Easy + Touch",  "45 min · brief speed at the end"),
        ("Fri", "Flush",         "easy · prepare for Saturday"),
        ("Sat", "Long Run",      "95 min · primary aerobic session"),
        ("Sun", "Easy",          "40 min · absorb the week"),
    ]

    private let arcPhases: [(label: String, purpose: String, duration: String)] = [
        ("Durability",  "Establish aerobic base and consistency.",           "4–6 wk"),
        ("Compression", "Increase load. Introduce quality. Hold structure.", "3–4 wk"),
        ("Economy",     "Refine form and efficiency at speed.",              "3–4 wk"),
        ("Sharpening",  "Reduce volume. Increase intensity. Peak.",         "2–3 wk"),
        ("Competition", "Race and recover. Minimal training stress.",       "variable"),
    ]

    private let doctrine = "The plan is not the performance. It is the preparation."
    private let cue      = "Follow the shape before trying to improve it."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            weekBlock
            arcBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Plan".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Plan")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Weekly structure — scannable rows, day column anchors each entry
    private var weekBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Weekly structure")
                .padding(.top, 20)
                .padding(.bottom, 4)
            ForEach(weekStructure, id: \.day) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.day)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.4)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.type)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            if !row.note.isEmpty {
                                Text(row.note)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(NativePalette.secondary)
                            }
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Arc phases — label + purpose + duration in a scan-first row
    private var arcBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Training arc · phases")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(arcPhases, id: \.label) { phase in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(phase.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(phase.purpose)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(phase.duration)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Native Strength page (index / structure grammar)
//
// What supports the running. Scan-first.
// Two surfaces: movement categories (what to do) + principles (how to approach it).
// Not a workout prescription — a map of the support system.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMStrengthNativeView: View {

    private let anchorLine = "The body runs on what it has built off the road."

    private let categories: [(label: String, examples: String, frequency: String)] = [
        ("Structural",   "single-leg work, hip stability, glute loading",   "2 × week"),
        ("Posterior",    "hip hinge, hamstring loading, calf work",         "2 × week"),
        ("Elastic",      "bounding, skipping, short plyometric series",     "1–2 × week"),
        ("Core",         "anti-rotation, bracing, hip flexor control",      "2–3 × week"),
        ("Mobility",     "hip flexor, ankle, thoracic, hamstring",          "daily"),
    ]

    private let principles: [(label: String, body: String)] = [
        (
            "Supplementary, not competing",
            "Strength work should not generate fatigue that degrades the primary sessions. Schedule it on easy days or after runs, not before hard sessions. The goal is support, not a second training stimulus."
        ),
        (
            "Consistency over complexity",
            "A simple set of movements done consistently every week beats an elaborate program done occasionally. Learn a handful of things. Do them well. Build the habit before adding variety."
        ),
        (
            "Running specificity",
            "The most relevant strength work mimics the demands of running: single-leg loading, hip extension, ankle stiffness, lateral stability. Bilateral exercises are useful but not sufficient. The body runs one leg at a time."
        ),
    ]

    private let doctrine = "Strength is not supplemental. It is structural."
    private let cue      = "Build what the run cannot build for itself."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            categoriesBlock
            principlesBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Strength".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Strength")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Movement categories — label + examples + frequency
    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Movement categories")
                .padding(.top, 20)
                .padding(.bottom, 4)
            ForEach(categories, id: \.label) { cat in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cat.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(cat.examples)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(cat.frequency)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Principles — editorial blocks, lighter than categoreis
    private var principlesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Approach")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(principles, id: \.label) { p in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(p.label.uppercased())
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(NativePalette.faint)
                            .tracking(1.6)
                        Text(p.body)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(NativePalette.bodyInk)
                            .lineSpacing(6)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                }
            }
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Cycles, The Work, Interruptions, The Field (stubs)
//
// Built in the next pass. Stubs here so the compiler resolves all
// PracticeSubPageView references before those pages are written.
// ─────────────────────────────────────────────────────────────────────────────

struct FORMCyclesNativeView: View {

    private let anchorLine = "Progression works by phase, not by urgency."

    private let cycleDefinitionText =
        "A training cycle is a planned arc of weeks that builds one quality at a time. Each cycle has a dominant purpose — base, threshold capacity, economy, or sharpening — and everything in the week serves that purpose. Trying to build all qualities simultaneously produces mediocre results across the board. The method chooses one and builds around it."

    private let cycleChangeText =
        "Volume, intensity, specificity, and recovery demand all shift from cycle to cycle. Durability carries high volume and low intensity. Compression raises both. Economy reduces volume and raises specificity. Sharpening cuts volume sharply and raises intensity. Competition holds the minimum needed to stay sharp. Each phase prepares the next."

    private let standardArc: [(label: String, purpose: String, duration: String)] = [
        ("Durability",  "Build aerobic base and structural resilience.",   "4–6 wk"),
        ("Compression", "Increase load. Introduce quality work.",          "3–4 wk"),
        ("Economy",     "Refine efficiency and form at speed.",            "3–4 wk"),
        ("Sharpening",  "Reduce volume. Increase intensity. Peak.",        "2–3 wk"),
        ("Competition", "Race and recover. Protect freshness.",            "variable"),
    ]

    private let doctrine = "Trust the sequence."
    private let cue      = "Each cycle is preparation for the one that follows."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            whatCycleBlock
            standardArcBlock
            cycleChangeBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Cycles".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Cycles")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var whatCycleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What a cycle is")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(cycleDefinitionText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly standard arc rows
    private var standardArcBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Standard arc")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(standardArc, id: \.label) { phase in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(phase.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(phase.purpose)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(phase.duration)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var cycleChangeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What changes across cycles")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(cycleChangeText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMTheWorkNativeView: View {

    private let anchorLine = "What we practice is not speed. It is repeatable quality."

    private let workIsText =
        "The work is not just completing sessions. It is learning to execute them correctly. That means holding the right effort, preserving form under load, and finishing with quality intact. The session is the container. The work is how you inhabit it."

    private let workIsNotText =
        "The work is not proving fitness, chasing exhaustion, or collecting hard days. A session completed incorrectly does not become more valuable because it felt intense. The method rewards precision, not theatrics. The athlete improves by repeating correct work long enough for it to become ordinary."

    private let practiceRows: [(label: String, purpose: String, cadence: String)] = [
        ("Restraint",  "Holding the assigned effort instead of forcing more.",                      "every week"),
        ("Rhythm",     "Finding repeatable timing in stride, breath, and attention.",               "every session"),
        ("Economy",    "Doing the same work at lower mechanical and metabolic cost.",               "over time"),
        ("Composure",  "Keeping form and decision-making clean under discomfort.",                  "key sessions"),
        ("Completion", "Finishing organized, not depleted or dramatic.",                            "always"),
    ]

    private let doctrine = "Quality repeated becomes capacity."
    private let cue      = "Run the session. Do not perform the session."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            workIsBlock
            practiceRowsBlock
            workIsNotBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · The Work".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("The Work")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var workIsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What the work is")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(workIsText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — structured rows
    private var practiceRowsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What we are practicing")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(practiceRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.purpose)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.cadence)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var workIsNotBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What the work is not")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(workIsNotText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMInterruptionsNativeView: View {

    private let anchorLine = "The system is built by what you protect from disruption."

    private let interruptionMeaningText =
        "An interruption is anything that breaks continuity without improving the work. Missed sleep, chaotic pacing, emotional overreach, excess intensity, inconsistent fueling, and social noise all count. The issue is not that disruption happens. The issue is pretending it has no training cost."

    private let interruptionActionsText =
        "Do not dramatize the disruption and do not try to repay it immediately. Return to structure as quickly and quietly as possible. One compromised day does not ruin a cycle. Escalation does. The correction is usually smaller than the reaction wants it to be."

    private let interruptionRows: [(label: String, description: String, cost: String)] = [
        ("Poor sleep",          "Reduces coordination, mood, and recovery quality.",                 "high cost"),
        ("Overpaced easy days", "Turns recovery sessions into moderate fatigue.",                    "common"),
        ("Underfueling",        "Lowers session quality and slows adaptation.",                      "accumulative"),
        ("Emotional theatrics", "Spends energy that should remain in the work.",                     "avoidable"),
        ("Inconsistency",       "Breaks the compounding effect of correct repetition.",              "structural"),
    ]

    private let doctrine = "Protect continuity."
    private let cue      = "Return to the work before you return to ambition."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            interruptionMeaningBlock
            interruptionRowsBlock
            interruptionActionsBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Interruptions".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Interruptions")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var interruptionMeaningBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What interruption means")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(interruptionMeaningText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly rows
    private var interruptionRowsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Common interruptions")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(interruptionRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.description)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.cost)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var interruptionActionsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What to do when interrupted")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(interruptionActionsText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMSpeedNativeView: View {

    private let anchorLine = "Speed is coordination under higher force."

    private let speedBuildsText =
        "Speed work is not primarily about moving fast. It is about learning to coordinate the body under higher mechanical demand. Short, controlled efforts train rhythm, posture, and elastic return while fatigue remains low. When speed work is executed correctly, the athlete leaves the session feeling sharper rather than exhausted."

    private let speedFitsText =
        "Speed sessions appear sparingly inside the method. They support threshold and long-run development by improving coordination and economy. Because the sessions are short and precise, they should never compromise the rest of the week. The athlete should leave feeling organized and ready for the next day of training."

    private let speedRows: [(label: String, detail: String, focus: String)] = [
        ("Coordination",           "Synchronizing arms, stride timing, and ground contact.",           "primary"),
        ("Elastic return",         "Using the body's natural spring rather than pushing harder.",      "mechanical"),
        ("Posture under force",    "Maintaining tall alignment when speed increases.",                 "structural"),
        ("Neuromuscular sharpness","Teaching the nervous system faster firing patterns.",              "neurological"),
        ("Restraint",              "Stopping the work before fatigue distorts form.",                  "discipline"),
    ]

    private let doctrine = "Speed reveals coordination."
    private let cue      = "Precision matters more than intensity."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            speedBuildsBlock
            speedRowsBlock
            speedFitsBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Speed".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Speed")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var speedBuildsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What speed work builds")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(speedBuildsText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly rows
    private var speedRowsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What speed sessions train")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(speedRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.detail)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.focus)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var speedFitsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "How speed fits the system")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(speedFitsText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMSessionsNativeView: View {

    private let anchorLine = "Each session has a role. The week works when the roles stay clear."

    private let sessionsAreText =
        "A session is not just a workout. It is a specific training demand placed inside the week for a reason. Threshold extends controlled discomfort. Long runs build endurance and economy. Easy days absorb load. Speed sharpens coordination. The system works when each session remains itself and does not drift into another role."

    private let sessionsFailText =
        "Sessions fail when they lose their identity. Easy days become moderate. Threshold becomes racing. Long runs become performances. Speed becomes fatigue. The athlete improves not by making every day hard, but by preserving the purpose of each session long enough for adaptation to accumulate."

    private let coreSessionRows: [(label: String, detail: String, focus: String)] = [
        ("Threshold", "Raises the ceiling for sustained work.",                     "quality"),
        ("Long Run",  "Builds endurance, rhythm, and durability over time.",       "aerobic"),
        ("Easy",      "Supports recovery while extending the base.",               "support"),
        ("Speed",     "Sharpens coordination under higher force.",                 "mechanical"),
        ("Flush",     "Clears fatigue without adding new stress.",                 "recovery"),
    ]

    private let doctrine = "The role of the session determines the value of the session."
    private let cue      = "Protect the purpose before chasing the feeling."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            sessionsAreBlock
            coreSessionsBlock
            sessionsFailBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Sessions".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Sessions")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var sessionsAreBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What sessions are")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(sessionsAreText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly rows
    private var coreSessionsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Core session types")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(coreSessionRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.detail)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.focus)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var sessionsFailBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "How sessions fail")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(sessionsFailText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMShoesNativeView: View {

    private let anchorLine = "Each shoe has a role. The rotation works when the roles stay clear."

    private let rotationIsText =
        "A shoe rotation is not about collecting options. It is about assigning the right tool to the right session. Easy shoes protect rhythm and reduce unnecessary cost. Session shoes sharpen feel and support higher-quality work. Race shoes are used sparingly so they remain specific. The rotation works when each shoe keeps its role."

    private let rotationUseText =
        "The point of the rotation is not novelty. It is preserving signal. The athlete should know what each shoe is for and avoid blurring roles without reason. Daily shoes absorb repetition. Session shoes support precision. Race shoes stay rare enough to remain meaningful. Clarity keeps the rotation useful."

    private let rotationRows: [(label: String, detail: String, role: String)] = [
        ("Cloudmonster 2",       "Easy and regulation runs.",              "daily"),
        ("Endorphin Speed",      "Threshold and steady long-run work.",    "session"),
        ("Alphafly 3",           "Reserved for race-specific use.",        "race"),
        ("Brooks Adrenaline GTS","Support option in rotation.",            "alternate"),
    ]

    private let doctrine = "The shoe should match the demand."
    private let cue      = "Use the tool for the work, not for the feeling."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            rotationIsBlock
            rotationRowsBlock
            rotationUseBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · Shoes".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("Shoes")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var rotationIsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What a rotation is")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(rotationIsText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly rows
    private var rotationRowsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Current rotation")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(rotationRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.detail)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.role)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var rotationUseBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "How to use the rotation")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(rotationUseText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

struct FORMTheFieldNativeView: View {

    private let anchorLine = "The environment shapes what the work becomes."

    private let fieldDefinitionText =
        "The field is the environment the training lives inside. It includes the route, the weather, the group, the culture, the timing, and the emotional tone surrounding the work. Training does not happen in abstraction. It happens in conditions. Good conditions make correct work easier to repeat."

    private let fieldWhyItMattersText =
        "A misaligned field can make good training difficult and bad training feel normal. The athlete adapts not only to the session, but to the conditions around it. A strong field protects quality, reduces distortion, and lets the work remain the center of attention."

    private let fieldRows: [(label: String, description: String, timing: String)] = [
        ("Clarity",   "The athlete knows what the session is asking.",              "before start"),
        ("Calm",      "The environment reduces unnecessary activation.",            "always"),
        ("Rhythm",    "Timing and flow support repeatable execution.",              "during work"),
        ("Restraint", "No surges, proving, or social distortion.",                  "group standard"),
        ("Return",    "The field leaves the athlete better organized after.",       "end state"),
    ]

    private let doctrine = "The field teaches the body what to expect."
    private let cue      = "Build conditions that make correctness easier."

    var body: some View {
        FORMReadingFrame {
            pageHeader
            fieldDefinitionBlock
            fieldRowsBlock
            fieldWhyItMattersBlock
            closingDoctrine
            Spacer(minLength: 56)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice · The Field".uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativePalette.faint)
                .tracking(1.4)
                .padding(.top, 24)
                .padding(.bottom, 20)
            Text("The Field")
                .font(.custom("Georgia", size: 36))
                .foregroundColor(NativePalette.titleInk)
                .tracking(0.2)
                .padding(.bottom, 8)
            Text(anchorLine)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.88))
                .tracking(0.2)
                .padding(.bottom, 36)
            PageRule(opacity: 0.42)
        }
    }

    // Section 1 — editorial prose block
    private var fieldDefinitionBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What the field is")
                .padding(.top, 24)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(fieldDefinitionText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    // Section 2 — scan-friendly rows
    private var fieldRowsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "What the field should provide")
                .padding(.top, 32)
                .padding(.bottom, 4)
            ForEach(fieldRows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 0) {
                    PageRule(opacity: 0.32)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(NativePalette.bodyInk)
                            Text(row.description)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(NativePalette.secondary)
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                        Spacer()
                        Text(row.timing)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(NativePalette.faint)
                            .tracking(0.3)
                    }
                }
            }
            PageRule(opacity: 0.42)
                .padding(.top, 2)
        }
    }

    // Section 3 — editorial prose block
    private var fieldWhyItMattersBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageLabel(text: "Why it matters")
                .padding(.top, 32)
                .padding(.bottom, 4)
            PageRule(opacity: 0.32)
            Text(fieldWhyItMattersText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(NativePalette.bodyInk)
                .lineSpacing(6)
                .padding(.top, 20)
                .padding(.bottom, 24)
            PageRule(opacity: 0.38)
        }
    }

    private var closingDoctrine: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)
            Text(doctrine)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(NativePalette.secondary.opacity(0.9))
                .tracking(0.5)
                .padding(.bottom, 16)
            Text(cue)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(NativePalette.faint.opacity(0.82))
                .padding(.bottom, 40)
            PageRule(opacity: 0.35)
        }
    }
}

// Shared stub header — same visual grammar, placeholder body
@ViewBuilder
private func stubHeader(title: String, anchor: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text("Practice · \(title)".uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(NativePalette.faint)
            .tracking(1.4)
            .padding(.top, 24)
            .padding(.bottom, 20)
        Text(title)
            .font(.custom("Georgia", size: 36))
            .foregroundColor(NativePalette.titleInk)
            .tracking(0.2)
            .padding(.bottom, 8)
        Text(anchor)
            .font(.system(size: 15, weight: .light))
            .foregroundColor(NativePalette.secondary)
            .padding(.bottom, 36)
        PageRule(opacity: 0.42)
        Spacer().frame(height: 60)
        Text("Coming next.")
            .font(.system(size: 15, weight: .light))
            .foregroundColor(NativePalette.faint)
            .padding(.bottom, 40)
        PageRule(opacity: 0.35)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — App entry point
// ─────────────────────────────────────────────────────────────────────────────

@main
struct FORMApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
