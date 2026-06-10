import Foundation

/// A Claude Code configuration directory (`CLAUDE_CONFIG_DIR`) monitored by the app.
///
/// The default profile lives at `~/.claude`; additional profiles follow the
/// `~/.claude-<name>` convention or can live anywhere when added manually.
nonisolated struct ClaudeProfile: Identifiable, Equatable {
    let directory: URL
    /// Whether this profile was found by scanning $HOME (vs. added manually).
    let isAutoDetected: Bool
    /// User-assigned label overriding the derived name.
    var customLabel: String?
    var isEnabled: Bool

    var id: String { directory.path }

    var projectsDirectory: URL {
        directory.appendingPathComponent("projects")
    }

    /// Name derived from the directory: `.claude` → "default",
    /// `.claude-<name>` → "<name>", anything else → the folder name.
    var derivedName: String {
        let dirName = directory.lastPathComponent
        if dirName == ".claude" { return "default" }
        if dirName.hasPrefix(".claude-") {
            return String(dirName.dropFirst(".claude-".count))
        }
        return dirName.hasPrefix(".") ? String(dirName.dropFirst()) : dirName
    }

    var displayName: String {
        if let customLabel, !customLabel.isEmpty { return customLabel }
        return derivedName
    }
}

/// Discovers and persists the set of Claude Code profiles.
///
/// Auto-detects `~/.claude` and `~/.claude-*` directories that look like real
/// config dirs (contain `projects/` or `settings.json`). Manual paths cover
/// `CLAUDE_CONFIG_DIR` locations outside $HOME. Enabled state and custom
/// labels persist in the App Group defaults.
@Observable
@MainActor
final class ProfileStore {

    private(set) var profiles: [ClaudeProfile] = []

    /// Invoked after any change to the profile list or its settings.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults?
    private let homeDirectory: URL
    private static let settingsKey = "claudeProfiles"

    var enabledProfiles: [ClaudeProfile] {
        profiles.filter(\.isEnabled)
    }

    init(
        defaults: UserDefaults? = AppGroup.defaults,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
        refresh()
    }

    // MARK: - Detection

    /// Re-scans $HOME for profile directories and merges them with stored settings.
    func refresh() {
        let stored = loadStored()
        var merged: [ClaudeProfile] = []

        for dir in detectProfileDirectories() {
            let saved = stored[dir.path]
            merged.append(ClaudeProfile(
                directory: dir,
                isAutoDetected: true,
                customLabel: saved?.label,
                isEnabled: saved?.enabled ?? true
            ))
        }

        for entry in stored.values where entry.manual {
            guard !merged.contains(where: { $0.directory.path == entry.path }) else { continue }
            merged.append(ClaudeProfile(
                directory: URL(fileURLWithPath: entry.path),
                isAutoDetected: false,
                customLabel: entry.label,
                isEnabled: entry.enabled
            ))
        }

        merged.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        if merged != profiles {
            profiles = merged
            onChange?()
        }
    }

    /// Directories in $HOME named `.claude` or `.claude-*` that look like config dirs.
    private func detectProfileDirectories() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: homeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        return entries.filter { url in
            let name = url.lastPathComponent
            guard name == ".claude" || name.hasPrefix(".claude-") else { return false }
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else {
                return false
            }
            return Self.looksLikeProfile(url)
        }
    }

    /// A directory counts as a profile if it has a `projects/` dir or `settings.json`.
    nonisolated static func looksLikeProfile(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.appendingPathComponent("projects").path, isDirectory: &isDir),
           isDir.boolValue {
            return true
        }
        return fm.fileExists(atPath: url.appendingPathComponent("settings.json").path)
    }

    // MARK: - Mutations

    func setEnabled(_ enabled: Bool, for profile: ClaudeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
              profiles[index].isEnabled != enabled else {
            return
        }
        profiles[index].isEnabled = enabled
        save()
        onChange?()
    }

    /// Sets a custom label. Empty input or the derived name clears the override.
    func setLabel(_ label: String, for profile: ClaudeProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLabel = (trimmed.isEmpty || trimmed == profiles[index].derivedName) ? nil : trimmed
        guard profiles[index].customLabel != newLabel else { return }
        profiles[index].customLabel = newLabel
        save()
        onChange?()
    }

    /// Adds a profile at a user-chosen location. Rejects directories that
    /// don't look like Claude Code config dirs, and duplicates.
    func addManualProfile(at url: URL) {
        let standardized = url.standardizedFileURL
        guard Self.looksLikeProfile(standardized),
              !profiles.contains(where: { $0.directory.path == standardized.path }) else {
            return
        }
        profiles.append(ClaudeProfile(
            directory: standardized,
            isAutoDetected: false,
            customLabel: nil,
            isEnabled: true
        ))
        profiles.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        save()
        onChange?()
    }

    func removeManualProfile(_ profile: ClaudeProfile) {
        guard !profile.isAutoDetected else { return }
        profiles.removeAll { $0.id == profile.id }
        save()
        onChange?()
    }

    // MARK: - Persistence

    private struct StoredProfile: Codable {
        let path: String
        let label: String?
        let enabled: Bool
        let manual: Bool
    }

    private func loadStored() -> [String: StoredProfile] {
        guard let data = defaults?.data(forKey: Self.settingsKey),
              let entries = try? JSONDecoder().decode([StoredProfile].self, from: data) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        let entries = profiles.map { profile in
            StoredProfile(
                path: profile.directory.path,
                label: profile.customLabel,
                enabled: profile.isEnabled,
                manual: !profile.isAutoDetected
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults?.set(data, forKey: Self.settingsKey)
    }
}
