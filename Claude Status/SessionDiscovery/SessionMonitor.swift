import Foundation
import WidgetKit

/// Monitors Claude Code sessions by scanning .cstatus files and filesystem state.
///
/// Sessions are discovered across all enabled profiles (Claude Code config dirs).
/// Uses three complementary mechanisms for timely updates:
/// 1. **Darwin notifications** — instant push from the hook script via `notifyutil -p`
/// 2. **File system watching** — `DispatchSource` on each profile's `projects/` dir
/// 3. **Polling timer** — 5s fallback for sessions without hooks (IDE agents, etc.)
@Observable
@MainActor
final class SessionMonitor {

    private(set) var sessions: [ClaudeSession] = []
    private(set) var productivityData: ProductivityData = ProductivityData(today: .empty(), allTime: .empty())

    /// The set of known Claude Code profiles (config dirs).
    let profileStore: ProfileStore

    /// Whether the Claude Code session-status plugin is installed in all enabled profiles.
    /// `true` = installed everywhere, `false` = missing in at least one enabled profile,
    /// `nil` = can't determine.
    private(set) var hookDetected: Bool?

    /// The most urgent state across all sessions, or nil if none.
    var aggregateState: SessionState? {
        sessions.map(\.state).max(by: { $0.priority < $1.priority })
    }

    private var discovery: SessionDiscovery
    private let stateResolver: StateResolver
    private let tracker: ProductivityTracker
    nonisolated(unsafe) private var timer: Timer?
    private let scanInterval: TimeInterval

    /// Maps session ID → .cstatus file URL for fast notification-driven refresh.
    private var cstatusCache: [String: URL] = [:]

    /// Cached plugin detection state and when it was last checked.
    private var lastPluginCheck: Date = .distantPast
    private var cachedPluginState: PluginInstallState = .unknown
    private static let pluginCheckInterval: TimeInterval = 30

    /// Throttle re-detection of profile directories in $HOME.
    private var lastProfileRefresh: Date = .distantPast
    private static let profileRefreshInterval: TimeInterval = 30

    /// Throttle widget reloads to avoid excessive writes on every 5s poll.
    private var lastWidgetUpdate: Date = .distantPast
    private static let widgetUpdateInterval: TimeInterval = 30

    /// Darwin notification name posted by the hook script.
    private static let darwinNotificationName = "com.poisonpenllc.Claude-Status.session-changed" as CFString

    init(scanInterval: TimeInterval = 5.0) {
        self.scanInterval = scanInterval
        self.discovery = SessionDiscovery()
        self.stateResolver = StateResolver()
        self.profileStore = ProfileStore()
        self.tracker = ProductivityTracker()
    }

    deinit {
        timer?.invalidate()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    func start() {
        stateResolver.onProjectsChanged = { [weak self] in
            self?.refresh()
        }

        profileStore.onChange = { [weak self] in
            self?.handleProfilesChanged()
        }
        updateWatchedDirectories()

        registerDarwinNotification()
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: scanInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        stateResolver.onProjectsChanged = nil
        profileStore.onChange = nil
        stateResolver.updateWatchedDirectories([])
        timer?.invalidate()
        timer = nil
        unregisterDarwinNotification()
    }

    // MARK: - Darwin Notifications

    private func registerDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<SessionMonitor>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.refreshFromNotification()
                }
            },
            Self.darwinNotificationName,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
    }

    // MARK: - Refresh

    /// Full refresh: directory scan + PID validation across all enabled profiles.
    /// Called on timer ticks and file system changes.
    func refresh() {
        refreshProfilesIfStale()
        let result = discovery.discoverAll(profiles: profileStore.enabledProfiles)
        applyResult(result)
    }

    /// Periodically re-detects profile directories so new `~/.claude-*` dirs
    /// show up without a restart.
    private func refreshProfilesIfStale() {
        let now = Date()
        guard now.timeIntervalSince(lastProfileRefresh) >= Self.profileRefreshInterval else { return }
        lastProfileRefresh = now
        profileStore.refresh()
    }

    /// Reacts to profile list/settings changes: rewires watchers and rescans.
    private func handleProfilesChanged() {
        updateWatchedDirectories()
        invalidatePluginCache()
        let result = discovery.discoverAll(profiles: profileStore.enabledProfiles)
        applyResult(result)
    }

    private func updateWatchedDirectories() {
        stateResolver.updateWatchedDirectories(
            profileStore.enabledProfiles.map(\.projectsDirectory)
        )
    }

    /// Notification-driven refresh: always do a full scan since the notification
    /// may signal a new session that isn't in our cache yet.
    private func refreshFromNotification() {
        discovery.clearDeadSessions()
        refresh()
    }

    /// Applies a discovery result: updates sessions, cache, and hook detection.
    /// Only writes to the shared container and reloads the widget when data changes.
    private func applyResult(_ result: SessionDiscovery.DiscoveryResult) {
        let sessionsChanged = sessions != result.sessions
        sessions = result.sessions
        cstatusCache = result.cstatusFiles

        // Track time-in-state for productivity scoring
        tracker.recordSnapshot(sessions: result.sessions)
        let newProductivity = tracker.currentData
        let productivityChanged = productivityData != newProductivity
        productivityData = newProductivity

        updatePluginState()

        // Session changes write immediately; productivity changes are throttled
        if sessionsChanged {
            writeToSharedContainer()
        } else if productivityChanged {
            let now = Date()
            if now.timeIntervalSince(lastWidgetUpdate) >= Self.widgetUpdateInterval {
                writeToSharedContainer()
            }
        }
    }

    /// Checks plugin installation state, caching the result to avoid
    /// reading JSON files from disk on every refresh cycle.
    private func updatePluginState() {
        let now = Date()
        if now.timeIntervalSince(lastPluginCheck) >= Self.pluginCheckInterval {
            cachedPluginState = Self.aggregatePluginState(for: profileStore.enabledProfiles)
            lastPluginCheck = now
        }
        switch cachedPluginState {
        case .installed: hookDetected = true
        case .notInstalled: hookDetected = false
        case .unknown: hookDetected = nil
        }
    }

    /// Plugin state across profiles: missing in any enabled profile wins,
    /// then undeterminable in any profile, otherwise installed if at least
    /// one profile has it.
    static func aggregatePluginState(for profiles: [ClaudeProfile]) -> PluginInstallState {
        var sawInstalled = false
        var sawUnknown = false
        for profile in profiles {
            switch PluginDetector(claudeDir: profile.directory).detect() {
            case .notInstalled: return .notInstalled
            case .installed: sawInstalled = true
            case .unknown: sawUnknown = true
            }
        }
        if sawUnknown { return .unknown }
        return sawInstalled ? .installed : .unknown
    }

    /// Forces a fresh plugin detection check (e.g. after install/uninstall).
    func invalidatePluginCache() {
        lastPluginCheck = .distantPast
    }

    // MARK: - Shared Data

    private func writeToSharedContainer() {
        guard let sharedURL = AppGroup.containerURL else {
            return
        }

        if let encoded = try? JSONEncoder().encode(sessions) {
            let dataURL = sharedURL.appendingPathComponent("sessions.json")
            try? encoded.write(to: dataURL, options: .atomic)
        }

        if let encoded = try? JSONEncoder().encode(productivityData) {
            let prodURL = sharedURL.appendingPathComponent("productivity.json")
            try? encoded.write(to: prodURL, options: .atomic)
        }

        lastWidgetUpdate = Date()

        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_StatusWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ProductivityWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ScoreWidget")
    }
}
