import Foundation

/// Detects whether the Claude Status hook/plugin is installed in a profile.
///
/// Checks two installation paths inside the profile's config dir:
/// 1. **Plugin** — `claude-status` in `<dir>/plugins/installed_plugins.json`
/// 2. **User hooks** — `session-status` references in `<dir>/settings.json` hooks
///
/// If either is found, the hook is considered installed.
enum PluginInstallState {
    /// The plugin or hooks are installed and active.
    case installed
    /// No plugin or hooks detected — sessions won't produce .cstatus files.
    case notInstalled
    /// Could not determine (e.g., the config dir doesn't exist).
    case unknown
}

struct PluginDetector {

    /// The profile's config directory (defaults to `~/.claude`).
    let claudeDir: URL

    init(
        claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    ) {
        self.claudeDir = claudeDir
    }

    /// Checks whether the session-status hook is available through any path.
    func detect() -> PluginInstallState {
        let pluginInstalled = checkInstalledPlugins()
        let hooksConfigured = checkSettingsHooks()

        if pluginInstalled || hooksConfigured {
            return .installed
        }

        // If ~/.claude doesn't exist at all, we can't determine
        let fm = FileManager.default
        if !fm.fileExists(atPath: claudeDir.path) {
            return .unknown
        }

        return .notInstalled
    }

    /// Returns the installed plugin version from `~/.claude/plugins/installed_plugins.json`,
    /// or nil if the plugin is not installed or the version can't be determined.
    func installedPluginVersion() -> String? {
        let url = claudeDir
            .appendingPathComponent("plugins/installed_plugins.json")

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else {
            return nil
        }

        // Find the claude-status plugin entry — value is an array of install records
        for (key, value) in plugins where key.hasPrefix("claude-status@") {
            guard let records = value as? [[String: Any]],
                  let latest = records.last,
                  let version = latest["version"] as? String else {
                continue
            }
            return version
        }
        return nil
    }

    // MARK: - Plugin Check

    /// Looks for any plugin key containing "claude-status" in installed_plugins.json,
    /// and verifies it's enabled in settings.json.
    private func checkInstalledPlugins() -> Bool {
        let url = claudeDir
            .appendingPathComponent("plugins/installed_plugins.json")

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else {
            return false
        }

        let installed = plugins.keys.contains { $0.hasPrefix("claude-status@") }
        guard installed else { return false }

        // Also verify it's enabled
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        guard let settingsData = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let enabled = settings["enabledPlugins"] as? [String: Bool] else {
            return installed // installed but can't check enabled — assume yes
        }

        return enabled.contains { $0.key.hasPrefix("claude-status@") && $0.value }
    }

    // MARK: - Settings Hooks Check

    /// Looks for session-status references in ~/.claude/settings.json hooks.
    private func checkSettingsHooks() -> Bool {
        let url = claudeDir
            .appendingPathComponent("settings.json")

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        // Check any hook event for a command referencing session-status
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookList {
                    if let command = hook["command"] as? String,
                       command.contains("session-status") {
                        return true
                    }
                }
            }
        }

        return false
    }
}
