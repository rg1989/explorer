import AppKit

/// The terminal app that "Open in Terminal" uses: the one picked in Settings,
/// else iTerm when it is installed, else Terminal. The folder is handed to the
/// app the way Finder hands it a dropped folder, so no shell command is built
/// (a folder name can't inject one) and no Automation permission is needed.
enum TerminalApp {
    struct App { let name: String; let bundleID: String; let url: URL }

    static let known: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
    ]

    /// Installed terminals that say they open folders.
    static var installed: [App] {
        known.compactMap { k in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: k.bundleID),
                  opensFolders(url) else { return nil }
            return App(name: k.name, bundleID: k.bundleID, url: url)
        }
    }

    static var preferred: App? {
        let all = installed
        if let id = Settings.terminalAppBundleID, let hit = all.first(where: { $0.bundleID == id }) { return hit }
        return all.first { $0.bundleID == "com.googlecode.iterm2" }
            ?? all.first { $0.bundleID == "com.apple.Terminal" } ?? all.first
    }

    static var menuTitle: String { "Open in \(preferred?.name ?? "Terminal")" }

    static func open(_ folder: URL) {
        guard let app = preferred else { NSSound.beep(); return }
        NSWorkspace.shared.open([folder], withApplicationAt: app.url,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    private static func opensFolders(_ appURL: URL) -> Bool {
        let types = (Bundle(url: appURL)?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        return types.contains { t in
            let uti = (t["LSItemContentTypes"] as? [String]) ?? []
            return uti.contains("public.folder") || uti.contains("public.directory")
        }
    }
}
