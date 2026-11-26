import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Stored preferences

struct Quote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
}

enum RotationInterval: String, CaseIterable, Identifiable {
    case never, quarterHour, hour, day
    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .quarterHour: return "Every 15 minutes"
        case .hour: return "Every hour"
        case .day: return "Every day"
        }
    }

    /// "Every day" means each new calendar day, so you get a fresh quote in the morning.
    func isDue(since last: Date, now: Date = Date()) -> Bool {
        switch self {
        case .never: return false
        case .quarterHour: return now.timeIntervalSince(last) >= 15 * 60
        case .hour: return now.timeIntervalSince(last) >= 60 * 60
        case .day: return !Calendar.current.isDate(last, inSameDayAs: now)
        }
    }
}

enum RotationOrder: String, CaseIterable, Identifiable {
    case sequential, random
    var id: String { rawValue }
}

enum Vertical: String, CaseIterable { case top, middle, bottom }
enum Horizontal: String, CaseIterable { case left, center, right }

/// One of nine spots on the screen, such as "top-left" or "middle-center".
struct Position: Hashable {
    var vertical: Vertical
    var horizontal: Horizontal

    var rawValue: String { "\(vertical.rawValue)-\(horizontal.rawValue)" }

    var title: String {
        if vertical == .middle && horizontal == .center { return "Center" }
        return "\(vertical.rawValue.capitalized) \(horizontal.rawValue)"
    }

    init(_ vertical: Vertical, _ horizontal: Horizontal) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    init?(rawValue: String) {
        // Values saved by older versions, which only had three positions.
        switch rawValue {
        case "top": self.init(.top, .center); return
        case "center": self.init(.middle, .center); return
        case "bottom": self.init(.bottom, .center); return
        default: break
        }
        let parts = rawValue.split(separator: "-").map(String.init)
        guard parts.count == 2,
              let vertical = Vertical(rawValue: parts[0]),
              let horizontal = Horizontal(rawValue: parts[1]) else { return nil }
        self.init(vertical, horizontal)
    }
}

enum TextAlign: String, CaseIterable, Identifiable {
    case auto, left, center, right
    var id: String { rawValue }

    /// Auto follows the position: text on the left edge aligns left, and so on.
    func resolved(for position: Position) -> NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .auto:
            switch position.horizontal {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }
}

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var quotes: [Quote] {
        get {
            if let data = defaults.data(forKey: "quotes"),
               let quotes = try? JSONDecoder().decode([Quote].self, from: data) {
                return quotes
            }
            // Older versions stored a single text.
            return [Quote(text: defaults.string(forKey: "text") ?? "Write your quote here.")]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "quotes")
            }
        }
    }

    static var shownID: UUID? {
        get { defaults.string(forKey: "shownQuote").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "shownQuote") }
    }

    static var rotation: RotationInterval {
        get { RotationInterval(rawValue: defaults.string(forKey: "rotation") ?? "") ?? .never }
        set { defaults.set(newValue.rawValue, forKey: "rotation") }
    }

    static var rotationOrder: RotationOrder {
        get { RotationOrder(rawValue: defaults.string(forKey: "rotationOrder") ?? "") ?? .sequential }
        set { defaults.set(newValue.rawValue, forKey: "rotationOrder") }
    }

    /// When the shown quote last changed, by hand or by rotation.
    static var lastRotation: Date {
        get { defaults.object(forKey: "lastRotation") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastRotation") }
    }

    /// The text on the desktop: the marked quote, or the first one.
    static var shownText: String {
        let all = quotes
        return (all.first { $0.id == shownID } ?? all.first)?.text ?? ""
    }

    static var font: NSFont {
        get {
            let stored = defaults.double(forKey: "fontSize")
            let size = stored > 0 ? CGFloat(stored) : 48
            let name = defaults.string(forKey: "fontName") ?? "HelveticaNeue-Light"
            return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: .light)
        }
        set {
            defaults.set(newValue.fontName, forKey: "fontName")
            defaults.set(Double(newValue.pointSize), forKey: "fontSize")
        }
    }

    static var color: NSColor {
        get {
            if let data = defaults.data(forKey: "color"),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                return color
            }
            return NSColor.white.withAlphaComponent(0.85)
        }
        set {
            let plain = newValue.usingColorSpace(.sRGB) ?? newValue
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: plain, requiringSecureCoding: true) {
                defaults.set(data, forKey: "color")
            }
        }
    }

    static var position: Position {
        get { Position(rawValue: defaults.string(forKey: "position") ?? "") ?? Position(.middle, .center) }
        set { defaults.set(newValue.rawValue, forKey: "position") }
    }

    static var alignment: TextAlign {
        get { TextAlign(rawValue: defaults.string(forKey: "alignment") ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "alignment") }
    }

    static var shadow: Bool {
        get { defaults.object(forKey: "shadow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shadow") }
    }
}

// MARK: - Overlay (the text on the desktop)

final class Overlay {
    private let window: NSWindow
    private let label = NSTextField(wrappingLabelWithString: "")
    private var verticalConstraint: NSLayoutConstraint?
    private var horizontalConstraint: NSLayoutConstraint?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Above the wallpaper and desktop icons, below every normal window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let content = NSView()
        window.contentView = content

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        content.addSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.7).isActive = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        refresh()
        window.orderFrontRegardless()
    }

    func refresh() {
        // The first screen is the one with the menu bar.
        guard let screen = NSScreen.screens.first, let content = window.contentView else { return }
        let frame = screen.visibleFrame
        window.setFrame(frame, display: true)

        let position = Prefs.position
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = Prefs.alignment.resolved(for: position)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Prefs.font,
            .foregroundColor: Prefs.color,
            .paragraphStyle: paragraph,
        ]
        if Prefs.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attributes[.shadow] = shadow
        }
        label.attributedStringValue = NSAttributedString(string: Prefs.shownText, attributes: attributes)
        label.preferredMaxLayoutWidth = frame.width * 0.7

        verticalConstraint?.isActive = false
        horizontalConstraint?.isActive = false
        let margin: CGFloat = 32
        switch position.vertical {
        case .top: verticalConstraint = label.topAnchor.constraint(equalTo: content.topAnchor, constant: margin)
        case .middle: verticalConstraint = label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        case .bottom: verticalConstraint = label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin)
        }
        switch position.horizontal {
        case .left: horizontalConstraint = label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin)
        case .center: horizontalConstraint = label.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        case .right: horizontalConstraint = label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin)
        }
        verticalConstraint?.isActive = true
        horizontalConstraint?.isActive = true
    }
}

// MARK: - Settings model

struct FontStyle: Hashable, Identifiable {
    let postScriptName: String
    let styleName: String
    var id: String { postScriptName }
}

final class SettingsModel: ObservableObject {
    /// Called after any change, so the overlay can redraw.
    var onChange: () -> Void = {}

    let families: [String] = NSFontManager.shared.availableFontFamilies

    @Published var quotes: [Quote] { didSet { Prefs.quotes = quotes; onChange() } }
    @Published var shownID: UUID? {
        didSet {
            Prefs.shownID = shownID
            Prefs.lastRotation = Date()
            onChange()
        }
    }
    @Published var rotation: RotationInterval {
        didSet { Prefs.rotation = rotation; Prefs.lastRotation = Date() }
    }
    @Published var rotationOrder: RotationOrder { didSet { Prefs.rotationOrder = rotationOrder } }
    /// The quote open in the editor. Not saved, and independent of the shown one.
    @Published var selectedID: UUID?
    @Published var family: String { didSet { familyChanged() } }
    @Published var fontName: String { didSet { saveFont() } }
    @Published var size: Double { didSet { saveFont() } }
    @Published var color: Color { didSet { Prefs.color = NSColor(color); onChange() } }
    @Published var position: Position { didSet { Prefs.position = position; onChange() } }
    @Published var alignment: TextAlign { didSet { Prefs.alignment = alignment; onChange() } }
    @Published var shadow: Bool { didSet { Prefs.shadow = shadow; onChange() } }
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    init() {
        let font = Prefs.font
        let storedQuotes = Prefs.quotes
        let storedShown = Prefs.shownID
        quotes = storedQuotes
        let shown = storedQuotes.contains { $0.id == storedShown } ? storedShown : storedQuotes.first?.id
        shownID = shown
        selectedID = shown
        rotation = Prefs.rotation
        rotationOrder = Prefs.rotationOrder
        family = font.familyName ?? "Helvetica Neue"
        fontName = font.fontName
        size = Double(font.pointSize)
        color = Color(nsColor: Prefs.color)
        position = Prefs.position
        alignment = Prefs.alignment
        shadow = Prefs.shadow
        // Property observers don't run in init; save once so migrated data gets stable IDs.
        Prefs.quotes = quotes
        Prefs.shownID = shownID
    }

    /// Show the next quote, in list order or at random. Empty quotes are skipped.
    func showNextQuote() {
        let hasText = { (quote: Quote) in !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let candidates = quotes.filter(hasText)
        guard !candidates.isEmpty else { return }

        switch rotationOrder {
        case .sequential:
            let start = quotes.firstIndex { $0.id == shownID } ?? -1
            for step in 1...quotes.count {
                let quote = quotes[(start + step + quotes.count) % quotes.count]
                if hasText(quote) {
                    shownID = quote.id
                    return
                }
            }
        case .random:
            let others = candidates.filter { $0.id != shownID }
            shownID = (others.randomElement() ?? candidates[0]).id
        }
    }

    func rotateIfDue() {
        if rotation.isDue(since: Prefs.lastRotation) {
            showNextQuote()
        }
    }

    func addQuote() {
        let quote = Quote(text: "")
        quotes.append(quote)
        if shownID == nil { shownID = quote.id }
        selectedID = quote.id
    }

    func removeQuote(_ id: UUID) {
        guard let index = quotes.firstIndex(where: { $0.id == id }) else { return }
        quotes.remove(at: index)
        let neighbor = quotes.isEmpty ? nil : quotes[min(index, quotes.count - 1)].id
        if shownID == id { shownID = neighbor }
        if selectedID == id { selectedID = neighbor }
    }

    func text(of id: UUID) -> Binding<String> {
        Binding(
            get: { self.quotes.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                if let index = self.quotes.firstIndex(where: { $0.id == id }) {
                    self.quotes[index].text = newValue
                }
            }
        )
    }

    var styles: [FontStyle] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard let name = member[0] as? String, let style = member[1] as? String else { return nil }
            return FontStyle(postScriptName: name, styleName: style)
        }
    }

    /// Keep the same style name ("Light", "Bold") when the family changes, if the new family has it.
    private func familyChanged() {
        let currentStyle = NSFont(name: fontName, size: 12)?.fontDescriptor.object(forKey: .face) as? String
        let options = styles
        let match = options.first { $0.styleName == currentStyle }
            ?? options.first { $0.styleName == "Regular" }
            ?? options.first
        if let match, match.postScriptName != fontName {
            fontName = match.postScriptName
        }
    }

    private func saveFont() {
        if let font = NSFont(name: fontName, size: CGFloat(size)) {
            Prefs.font = font
        }
        onChange()
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Settings window

struct QuotesTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            rotationBar
        }
    }

    private var rotationBar: some View {
        HStack(spacing: 16) {
            Picker("Change quote", selection: $model.rotation) {
                ForEach(RotationInterval.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("Order", selection: $model.rotationOrder) {
                Text("In order").tag(RotationOrder.sequential)
                Text("Random").tag(RotationOrder.random)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.rotation == .never)
            Spacer()
            Button("Next Quote", action: model.showNextQuote)
                .disabled(model.quotes.count < 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selectedID) {
                    ForEach(model.quotes) { quote in
                        row(quote).tag(quote.id)
                    }
                    .onMove { model.quotes.move(fromOffsets: $0, toOffset: $1) }
                }
                .onDeleteCommand {
                    if let id = model.selectedID { model.removeQuote(id) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button(action: model.addQuote) {
                        Image(systemName: "plus").frame(width: 24, height: 22)
                    }
                    .help("Add a quote")
                    Button {
                        if let id = model.selectedID { model.removeQuote(id) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .disabled(model.selectedID == nil)
                    .help("Delete the selected quote")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 220)

            Divider()

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ quote: Quote) -> some View {
        let shown = quote.id == model.shownID
        let firstLine = quote.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return HStack(spacing: 8) {
            Button {
                model.shownID = quote.id
            } label: {
                Image(systemName: shown ? "circle.fill" : "circle")
                    .foregroundStyle(shown ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(shown ? "Shown on the desktop" : "Show on the desktop")
            Text(firstLine.isEmpty ? "New quote" : firstLine)
                .lineLimit(1)
                .foregroundStyle(firstLine.isEmpty ? .secondary : .primary)
        }
        .contextMenu {
            Button("Show on Desktop") { model.shownID = quote.id }
            Button("Delete", role: .destructive) { model.removeQuote(quote.id) }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = model.selectedID, model.quotes.contains(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if id == model.shownID {
                        Label("Shown on the desktop", systemImage: "circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Show on Desktop") { model.shownID = id }
                    }
                    Spacer()
                }
                .frame(height: 24)
                TextEditor(text: model.text(of: id))
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .id(id)
            }
            .padding(16)
        } else {
            Text(model.quotes.isEmpty ? "Click + to add a quote." : "Select a quote to edit it.")
                .foregroundStyle(.secondary)
        }
    }
}

struct AppearanceTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $model.family) {
                    ForEach(model.families, id: \.self) { Text($0).tag($0) }
                }
                Picker("Style", selection: $model.fontName) {
                    ForEach(model.styles) { Text($0.styleName).tag($0.postScriptName) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $model.size, in: 12...160, step: 1)
                        Text("\(Int(model.size)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                ColorPicker("Color", selection: $model.color, supportsOpacity: true)
            }

            Section("Layout") {
                LabeledContent("Position") {
                    VStack(alignment: .trailing, spacing: 6) {
                        PositionGrid(selection: $model.position)
                        Text(model.position.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Alignment", selection: $model.alignment) {
                    Text("Auto").tag(TextAlign.auto)
                    Image(systemName: "text.alignleft").tag(TextAlign.left)
                    Image(systemName: "text.aligncenter").tag(TextAlign.center)
                    Image(systemName: "text.alignright").tag(TextAlign.right)
                }
                .pickerStyle(.segmented)
                Toggle("Text shadow", isOn: $model.shadow)
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

/// A small screen with a 3×3 grid of spots to place the text.
struct PositionGrid: View {
    @Binding var selection: Position

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Vertical.allCases, id: \.self) { vertical in
                GridRow {
                    ForEach(Horizontal.allCases, id: \.self) { horizontal in
                        cell(Position(vertical, horizontal))
                    }
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }

    private func cell(_ position: Position) -> some View {
        let selected = position == selection
        return Button {
            selection = position
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.18))
                .frame(width: 40, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(position.title)
    }
}

// MARK: - App and menu bar item

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: Overlay!
    private var model: SettingsModel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = Overlay()
        model = SettingsModel()
        model.onChange = { [weak self] in self?.overlay.refresh() }
        installEditMenu()

        // Rotation: check twice a minute, after waking from sleep, and now.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.model.rotateIfDue()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.model.rotateIfDue() }
        model.rotateIfDue()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Desk Quote")
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let next = NSMenuItem(title: "Next Quote", action: #selector(showNextQuote), keyEquivalent: "n")
        next.target = self
        menu.addItem(next)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Desk Quote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showNextQuote() {
        model.showNextQuote()
    }

    // Opening the app again while it runs (Finder, Spotlight, `open`) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            // Native settings tabs: icons in the toolbar, one page per tab.
            let size = CGSize(width: 620, height: 520)
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for (title, symbol, view) in [
                ("Quotes", "text.quote", AnyView(QuotesTab(model: model))),
                ("Appearance", "textformat", AnyView(AppearanceTab(model: model))),
            ] {
                let page = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
                page.sizingOptions = []
                page.view.frame.size = size
                page.preferredContentSize = size
                page.title = title
                let item = NSTabViewItem(viewController: page)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.toolbarStyle = .preference
            window.title = "Quotes"
            window.setContentSize(size)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Menu-bar-only apps have no Edit menu, so ⌘C/⌘V/⌘Z would not work in text fields without this.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
