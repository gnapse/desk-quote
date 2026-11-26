import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Stored preferences

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

    static var text: String {
        get { defaults.string(forKey: "text") ?? "Write your quote here." }
        set { defaults.set(newValue, forKey: "text") }
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
        label.attributedStringValue = NSAttributedString(string: Prefs.text, attributes: attributes)
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

    @Published var text: String { didSet { Prefs.text = text; onChange() } }
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
        text = Prefs.text
        family = font.familyName ?? "Helvetica Neue"
        fontName = font.fontName
        size = Double(font.pointSize)
        color = Color(nsColor: Prefs.color)
        position = Prefs.position
        alignment = Prefs.alignment
        shadow = Prefs.shadow
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Text") {
                TextEditor(text: $model.text)
                    .font(.system(size: 14))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
            }

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
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Desk Quote")
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Desk Quote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // Opening the app again while it runs (Finder, Spotlight, `open`) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Desk Quote"
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
