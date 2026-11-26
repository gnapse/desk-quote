import AppKit
import ServiceManagement

// MARK: - Settings

enum Position: String, CaseIterable {
    case top, center, bottom
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
            if let name = defaults.string(forKey: "fontName"), let font = NSFont(name: name, size: size) {
                return font
            }
            return NSFont.systemFont(ofSize: size, weight: .light)
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
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                defaults.set(data, forKey: "color")
            }
        }
    }

    static var position: Position {
        get { Position(rawValue: defaults.string(forKey: "position") ?? "") ?? .center }
        set { defaults.set(newValue.rawValue, forKey: "position") }
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
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.7),
        ])

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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
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
        let margin: CGFloat = 32
        switch Prefs.position {
        case .top: verticalConstraint = label.topAnchor.constraint(equalTo: content.topAnchor, constant: margin)
        case .center: verticalConstraint = label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        case .bottom: verticalConstraint = label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin)
        }
        verticalConstraint?.isActive = true
    }
}

// MARK: - Text editor window

final class Editor: NSObject, NSTextViewDelegate {
    private let window: NSWindow
    private let textView: NSTextView
    private let onChange: (String) -> Void

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = "Desk Quote"
        window.isReleasedWhenClosed = false

        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()

        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = self

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = .command
        let hint = NSTextField(labelWithString: "Changes show on the desktop as you type. ⌘↩ to close.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let content = NSView()
        for view in [scroll, done, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            done.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            done.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
        ])
        window.contentView = content
    }

    func show() {
        textView.string = Prefs.text
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        onChange(textView.string)
    }

    @objc private func close() {
        window.close()
    }
}

// MARK: - App and menu bar item

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var overlay: Overlay!
    private var editor: Editor!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = Overlay()
        editor = Editor { [weak self] text in
            Prefs.text = text
            self?.overlay.refresh()
        }
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Desk Quote")
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Edit Text…", #selector(editText), "e"))
        menu.addItem(item("Font…", #selector(showFonts), "t"))
        menu.addItem(item("Color…", #selector(showColors), "c"))

        let positionMenu = NSMenu()
        for position in Position.allCases {
            let entry = item(position.rawValue.capitalized, #selector(setPosition(_:)))
            entry.representedObject = position.rawValue
            entry.state = Prefs.position == position ? .on : .off
            positionMenu.addItem(entry)
        }
        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        let shadow = item("Text Shadow", #selector(toggleShadow))
        shadow.state = Prefs.shadow ? .on : .off
        menu.addItem(shadow)

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Desk Quote", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        return entry
    }

    @objc private func editText() {
        editor.show()
    }

    @objc private func showFonts() {
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(Prefs.font, isMultiple: false)
        NSApp.activate(ignoringOtherApps: true)
        manager.orderFrontFontPanel(nil)
    }

    // Sent by the font panel.
    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        Prefs.font = manager.convert(Prefs.font)
        overlay.refresh()
    }

    @objc private func showColors() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = Prefs.color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        Prefs.color = sender.color
        overlay.refresh()
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = Position(rawValue: raw) else { return }
        Prefs.position = position
        overlay.refresh()
    }

    @objc private func toggleShadow() {
        Prefs.shadow.toggle()
        overlay.refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    // Menu-bar-only apps have no Edit menu, so ⌘C/⌘V/⌘Z would not work in the editor without this.
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
