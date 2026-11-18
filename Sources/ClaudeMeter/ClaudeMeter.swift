import AppKit
import Network

@main
@MainActor
final class ClaudeMeter: NSObject, NSApplicationDelegate {
    private let service = TrustScoreService()
    private let networkMonitor = NWPathMonitor()
    private let menu = NSMenu()
    private let claudeIPItem = NSMenuItem()
    private let publicIPItem = NSMenuItem()
    private let statusItem = NSMenuItem()
    private var menuBarItem: NSStatusItem?
    private var timer: Timer?
    private var check: Task<Void, Never>?
    private var claudeIP: String?
    private var score: Double?

    static func main() {
        let application = NSApplication.shared
        let delegate = ClaudeMeter()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenu()
        // The monitor delivers the current path on startup and subsequent path changes.
        networkMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh(networkChanged: true) }
        }
        networkMonitor.start(queue: DispatchQueue(label: "ClaudeMeter.network"))

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        networkMonitor.cancel()
        check?.cancel()
    }

    private func setUpMenu() {
        menu.autoenablesItems = false
        for item in [claudeIPItem, publicIPItem, statusItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let exitItem = NSMenuItem(title: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        exitItem.target = NSApplication.shared
        menu.addItem(exitItem)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu
        item.button?.imagePosition = .imageLeft
        menuBarItem = item
        showPublicIP(nil)
        updateMenu(status: "Определяем IP Claude…")
    }

    @objc private func refreshNow() {
        refresh()
    }

    private func refresh(networkChanged: Bool = false) {
        if networkChanged {
            check?.cancel()
            claudeIP = nil
            score = nil
            showPublicIP(nil)
        } else if check != nil {
            return
        }

        updateMenu(status: "Проверяем IP Claude…")
        check = Task { [weak self] in await self?.runCheck() }
    }

    private func runCheck() async {
        async let claudeCheck: Void = updateClaudeScore()
        async let publicCheck: Void = updatePublicIP()
        _ = await (claudeCheck, publicCheck)
        if !Task.isCancelled { check = nil }
    }

    private func updatePublicIP() async {
        let ip = try? await service.publicIP()
        guard !Task.isCancelled else { return }
        showPublicIP(ip)
    }

    private func updateClaudeScore() async {
        do {
            let currentIP = try await service.claudeIP()
            try Task.checkCancellation()
            if claudeIP != currentIP {
                claudeIP = currentIP
                score = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            claudeIP = nil
            score = nil
            updateMenu(status: "Не удалось определить IP Claude", detail: error.localizedDescription)
            return
        }

        guard let claudeIP else { return }
        updateMenu(status: "Запрашиваем индекс…")
        do {
            let currentScore = try await service.score(for: claudeIP)
            try Task.checkCancellation()
            score = currentScore
            updateMenu(status: "Обновлено в \(Date.now.formatted(date: .omitted, time: .standard))")
        } catch {
            guard !Task.isCancelled else { return }
            score = nil
            updateMenu(status: "Индекс недоступен", detail: error.localizedDescription)
        }
    }

    private func showPublicIP(_ ip: String?) {
        publicIPItem.title = "Внешний IP · \(ip ?? "—")"
    }

    private func updateMenu(status: String, detail: String? = nil) {
        claudeIPItem.title = "IP Claude · \(claudeIP ?? "—")"
        statusItem.title = status
        statusItem.toolTip = detail

        guard let button = menuBarItem?.button else { return }
        let number = score?.formatted(.number.precision(.fractionLength(0...2))) ?? "—"
        let color = score.map { value in
            NSColor(hue: (value / 100) / 3, saturation: 0.9, brightness: 0.82, alpha: 1)
        } ?? .secondaryLabelColor
        button.attributedTitle = NSAttributedString(string: number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: color
        ])
        let dot = NSImage(size: NSSize(width: 10, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
            return true
        }
        dot.isTemplate = false
        button.image = dot
        let description = score == nil ? "Trust Score: —" : "Trust Score: \(number) / 100"
        button.setAccessibilityLabel("ClaudeMeter · \(description)")
        button.toolTip = [description, claudeIPItem.title, detail ?? status].joined(separator: "\n")
    }
}
