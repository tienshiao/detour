import AppKit

/// Which source a built app came from (TASK-321). The version and build
/// number alone don't say whether a locally built or installed app contains a
/// given fix; the commit does.
enum BuildInfo {
    /// Info.plist key the "Stamp git commit" build phase writes into the
    /// built app's Info.plist (never the source one): the short hash, with
    /// "-dirty" when tracked files differed from HEAD at build time.
    static let commitInfoKey = "DetourGitCommit"

    /// The commit the running app was built from, or nil when the build phase
    /// could not stamp one (no git, not a checkout).
    static var commit: String? {
        Bundle.main.object(forInfoDictionaryKey: commitInfoKey) as? String
    }

    /// The parenthesised part of About's "Version 0.4.2 (…)": the build
    /// number, followed by the commit when there is one.
    nonisolated static func aboutPanelVersion(build: String?, commit: String?) -> String? {
        let parts = [build, commit].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func showAboutPanel() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let version = aboutPanelVersion(build: build, commit: commit) {
            options[.version] = version
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
