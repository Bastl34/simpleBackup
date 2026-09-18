import AppKit
import Combine
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        signal(SIGPIPE, SIG_IGN) // in case 7zz dies before we've written the password
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let settings = Settings.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let backupMenu = NSMenu()
    private lazy var startItem = menuItem(String(localized: "Start Backup"), symbol: "play.circle", action: nil)
    private let quitItem = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    private var jobs: [BackupJob] = []
    private var settingsWindow: NSWindow?
    private var quitting = false
    private var entriesObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        UNUserNotificationCenter.current().delegate = self

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.button?.setAccessibilityLabel("simpleBackup")

        startItem.submenu = backupMenu
        quitItem.image = symbol("power")
        menu.items = [
            startItem,
            .separator(),
            menuItem(String(localized: "Settings…"), symbol: "gearshape", action: #selector(openSettings), key: ","),
            menuItem(String(localized: "About simpleBackup"), symbol: "info.circle", action: #selector(showAbout)),
            .separator(),
            quitItem,
        ]
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        // keep the "backup due" state current: on every settings change and every few minutes
        entriesObserver = settings.$entries.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)

        refresh()
        if settings.entries.isEmpty { openSettings() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !jobs.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "A backup is still running")
        alert.informativeText = String(localized: "Quitting will cancel all running backups.")
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Cancel Backups and Quit")).hasDestructiveAction = true
        guard run(alert) == .alertSecondButtonReturn else { return .terminateCancel }
        quitting = true
        jobs.forEach { $0.stop() }
        return .terminateLater // confirmed in finished() once all 7zz processes have cleaned up
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        backupMenu.removeAllItems()
        for entry in settings.entries {
            let item = menuItem(entry.title, symbol: "folder", action: #selector(toggleBackup(_:)))
            item.representedObject = entry.id
            item.toolTip = "\(entry.source) → \(entry.destination)"
            backupMenu.addItem(item)
        }
        if settings.entries.isEmpty {
            backupMenu.addItem(withTitle: String(localized: "No folders set up"), action: nil, keyEquivalent: "")
        }
        refresh()
    }

    /// Updates the menu bar icon and menu items for running and due backups (also while the menu is open).
    @objc private func refresh() {
        let due = settings.entries.filter { entry in entry.isDue && !jobs.contains { $0.entry.id == entry.id } }
        if let button = statusItem.button {
            if !jobs.isEmpty {
                let values = jobs.map(\.progress)
                button.image = ProgressRing.image(values)
                button.title = " " + (values.reduce(0, +) / Double(values.count)).formatted(.percent.precision(.fractionLength(0)))
            } else {
                button.image = due.isEmpty ? Self.idleIcon : symbol(Self.dueSymbol, size: 15, orange: true)
                button.title = ""
            }
            let names = due.map(\.title).formatted(.list(type: .and))
            button.toolTip = due.isEmpty ? nil : String(localized: "Backup due: \(names)")
        }
        startItem.image = due.isEmpty ? symbol("play.circle") : symbol(Self.dueSymbol, orange: true)
        quitItem.isEnabled = jobs.isEmpty
        quitItem.toolTip = jobs.isEmpty ? nil : String(localized: "You can quit once no backup is running.")

        for item in backupMenu.items {
            guard let id = item.representedObject as? UUID,
                  let entry = settings.entries.first(where: { $0.id == id }) else { continue }
            let job = jobs.first { $0.entry.id == id }
            if let job {
                let percent = job.progress.formatted(.percent.precision(.fractionLength(0)))
                item.title = String(localized: "Stop \(entry.title) – \(percent)")
                item.image = ProgressRing.image([job.progress], size: 16)
            } else {
                item.title = entry.title
                item.image = entry.isDue ? symbol(Self.dueSymbol, orange: true) : symbol("folder")
            }
            if #available(macOS 14.4, *) {
                // the archive that would be created (+ when the last one was made), or the one currently being written
                let ago = entry.lastBackup?.formatted(.relative(presentation: .numeric))
                let last = ago.map { String(localized: "Last backup: \($0)") } ?? String(localized: "No backup yet")
                item.subtitle = job?.target.lastPathComponent ?? "\(entry.archiveName())\n\(last)"
            }
        }
    }

    @objc private func toggleBackup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        if let job = jobs.first(where: { $0.entry.id == id }) {
            job.stop()
        } else if let entry = settings.entries.first(where: { $0.id == id }) {
            start(entry)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            window.title = String(localized: "simpleBackup Settings")
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(string: String(localized: "Encrypted 7-Zip backups from the menu bar."), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - Backup

    private func start(_ entry: BackupEntry) {
        guard FileManager.default.isExecutableFile(atPath: settings.sevenZip) else {
            return showAlert(String(localized: "7zz not found"),
                             String(localized: "There is no 7zz at “\(settings.sevenZip)”. Install it with “brew install sevenzip” or change the path in Settings."))
        }
        guard isFolder(entry.source) else {
            return showAlert(String(localized: "Folder not found"),
                             String(localized: "“\(entry.source)” does not exist (anymore)."))
        }
        guard isFolder(entry.destination) else {
            return showAlert(String(localized: "Backup destination not found"),
                             String(localized: "“\(entry.destination)” is not reachable. Is the drive connected?"))
        }
        guard let target = chooseTarget(for: entry), let password = password(for: entry) else { return }

        let job = BackupJob(entry: entry, target: target, sevenZip: settings.sevenZip)
        job.onProgress = { [weak self] in self?.refresh() }
        job.onFinish = { [weak self] job, outcome in self?.finished(job, outcome) }
        do {
            try job.start(password: password)
            jobs.append(job)
            refresh()
        } catch {
            showAlert(String(localized: "The backup could not be started"), error.localizedDescription)
        }
    }

    private func finished(_ job: BackupJob, _ outcome: BackupJob.Outcome) {
        jobs.removeAll { $0 === job }
        switch outcome {
        case .success, .warnings: settings.update(job.entry.id) { $0.lastBackup = .now }
        case .failed, .stopped: break
        }
        refresh()
        if quitting {
            if jobs.isEmpty { NSApp.reply(toApplicationShouldTerminate: true) }
            return
        }
        switch outcome {
        case .success:
            notify(String(localized: "Backup finished"), job.target.lastPathComponent)
        case .warnings(let text):
            showAlert(String(localized: "Backup “\(job.entry.title)” finished with warnings"),
                      "\(job.target.lastPathComponent)\n\n\(text)")
        case .failed(let text):
            showAlert(String(localized: "Backup “\(job.entry.title)” failed"), text)
        case .stopped:
            break
        }
    }

    /// Picks the archive file; if it already exists, asks whether to overwrite it or create "-2", "-3", …
    private func chooseTarget(for entry: BackupEntry) -> URL? {
        let folder = URL(fileURLWithPath: entry.destination)
        func file(_ n: Int) -> URL { folder.appendingPathComponent(entry.archiveName(n)) }
        func taken(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path) || jobs.contains { $0.target == url }
        }
        guard taken(file(1)) else { return file(1) }
        var n = 2
        while taken(file(n)) { n += 1 }

        let alert = NSAlert()
        alert.messageText = String(localized: "“\(file(1).lastPathComponent)” already exists")
        alert.informativeText = String(localized: "Do you want to overwrite the existing backup or create a new file?")
        alert.addButton(withTitle: String(localized: "New File “\(file(n).lastPathComponent)”"))
        alert.addButton(withTitle: String(localized: "Overwrite")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch run(alert) {
        case .alertFirstButtonReturn: return file(n)
        case .alertSecondButtonReturn: return file(1)
        default: return nil
        }
    }

    private func password(for entry: BackupEntry) -> String? {
        if entry.savePassword, let saved = Keychain.password(for: entry.id) { return saved }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 22))
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = String(localized: "Password")
        confirmation.placeholderString = String(localized: "Repeat")
        field.nextKeyView = confirmation
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        fields.addSubview(field)
        fields.addSubview(confirmation)

        let alert = NSAlert()
        alert.messageText = String(localized: "Password for “\(entry.title)”")
        alert.informativeText = String(localized: "The backup is encrypted with it, including file names.")
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Start Backup"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Save in Keychain")
        alert.suppressionButton?.state = entry.savePassword ? .on : .off
        alert.layout()
        alert.window.initialFirstResponder = field

        while run(alert) == .alertFirstButtonReturn {
            let password = field.stringValue
            guard !password.isEmpty, password == confirmation.stringValue else {
                alert.informativeText = String(localized: "The passwords don't match.")
                continue
            }
            if alert.suppressionButton?.state == .on, Keychain.save(password, for: entry) {
                settings.update(entry.id) { $0.savePassword = true }
            }
            return password
        }
        return nil
    }

    // MARK: - Helpers

    /// Menu item with an SF Symbol in front, so all items look the same on every macOS version.
    private func menuItem(_ title: String, symbol name: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol(name)
        return item
    }

    private static let dueSymbol = "exclamationmark.arrow.circlepath"

    /// The ring of "lock.rotation" (= mirrored "arrow.circlepath") with a drive in the middle instead of the lock.
    private static let idleIcon: NSImage = {
        let ring = NSImage(systemSymbolName: "arrow.circlepath", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let drive = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))!
        let image = NSImage(size: ring.size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let mirror = NSAffineTransform()
            mirror.translateX(by: rect.width, yBy: 0)
            mirror.scaleX(by: -1, yBy: 1)
            mirror.concat()
            ring.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            drive.draw(in: NSRect(x: rect.midX - drive.size.width / 2, y: rect.midY - drive.size.height / 2,
                                  width: drive.size.width, height: drive.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// SF Symbol; orange ones are colored (not template), so they stay orange in the menu bar too.
    private func symbol(_ name: String, size: CGFloat? = nil, orange: Bool = false) -> NSImage? {
        var config = size.map { NSImage.SymbolConfiguration(pointSize: $0, weight: .regular) } ?? NSImage.SymbolConfiguration()
        if orange { config = config.applying(.init(paletteColors: [.systemOrange])) }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        _ = run(alert)
    }

    private func notify(_ title: String, _ body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound] // show it even while the settings window is active
    }

    /// Without a main menu, ⌘C/⌘V/⌘W don't work in the settings window. It's never visible, so no localization needed.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}

/// Concentric progress rings – one per running backup (max. 3), as a template image for the menu bar.
enum ProgressRing {
    static func image(_ values: [Double], size: CGFloat = 18) -> NSImage {
        let rings = Array(values.prefix(3))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = [2.5, 2, 1.5][max(rings.count, 1) - 1] * size / 18
            let center = NSPoint(x: rect.midX, y: rect.midY)
            var radius = size / 2 - lineWidth / 2 - 0.5
            for value in rings {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = lineWidth
                NSColor.black.withAlphaComponent(0.25).setStroke()
                track.stroke()

                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * max(value, 0.001), clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()

                radius -= lineWidth + 1
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
