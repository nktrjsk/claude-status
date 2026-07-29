import Foundation

/// Resolves session state from JSONL files as a fallback for sessions without .cstatus files.
/// Also watches each profile's projects directory for filesystem changes.
@MainActor
final class StateResolver {

    /// Active directory watchers, keyed by watched path.
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Callback invoked when any watched projects directory changes.
    var onProjectsChanged: (() -> Void)?

    deinit {
        // Cancel the watchers; each cancel handler closes its file descriptor.
        for watcher in fileWatchers.values {
            watcher.cancel()
        }
    }

    /// Resolves state from JSONL modification times for a given project directory.
    /// Only used as a fallback when no .cstatus file is available.
    func resolveFromJSONL(in projectDir: URL) -> (state: SessionState, lastActivity: Date) {
        guard let (newestFile, lastModified) = mostRecentJSONLFile(in: projectDir) else {
            return (.idle, .distantPast)
        }

        let interval = Date().timeIntervalSince(lastModified)

        if interval < 5 {
            return (.active, lastModified)
        }

        let lastLineState = stateFromLastMeaningfulLine(of: newestFile)

        switch lastLineState {
        case .assistantWorking:
            if interval < 30 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .assistantDone:
            if interval < 10 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .userMessage:
            if interval < 30 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .noMeaningfulMessage:
            return (.idle, lastModified)
        }
    }

    // MARK: - File Watching

    /// Reconciles the active watchers with the given set of projects directories:
    /// drops watchers for removed dirs, adds watchers for new ones.
    func updateWatchedDirectories(_ directories: [URL]) {
        let newPaths = Set(directories.map(\.path))

        for path in Set(fileWatchers.keys).subtracting(newPaths) {
            fileWatchers[path]?.cancel()
            fileWatchers[path] = nil
        }

        for dir in directories where fileWatchers[dir.path] == nil {
            if let watcher = makeFileWatcher(for: dir) {
                fileWatchers[dir.path] = watcher
            }
        }
    }

    private func makeFileWatcher(for projectsDir: URL) -> DispatchSourceFileSystemObject? {
        try? FileManager.default.createDirectory(
            at: projectsDir,
            withIntermediateDirectories: true
        )

        let fileDescriptor = open(projectsDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.onProjectsChanged?()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        return source
    }

    // MARK: - JSONL Helpers

    private func mostRecentJSONLFile(in directory: URL) -> (URL, Date)? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast
        for url in contents where url.pathExtension == "jsonl" {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               modified > newestDate {
                newestDate = modified
                newestURL = url
            }
        }

        guard let url = newestURL, newestDate != .distantPast else {
            return nil
        }
        return (url, newestDate)
    }

    // MARK: - Last Line Parsing

    private enum LastLineState {
        case assistantWorking
        case assistantDone
        case userMessage
        case noMeaningfulMessage
    }

    private static let meaningfulTypes: Set<String> = ["user", "assistant"]

    private func stateFromLastMeaningfulLine(of fileURL: URL) -> LastLineState {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .noMeaningfulMessage
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return .noMeaningfulMessage
        }

        let tailSize: UInt64 = min(fileSize, 64 * 1024)
        let seekPos = fileSize - tailSize

        do {
            try handle.seek(toOffset: seekPos)
        } catch {
            return .noMeaningfulMessage
        }

        guard let data = try? handle.read(upToCount: Int(tailSize)),
              let tail = String(data: data, encoding: .utf8) else {
            return .noMeaningfulMessage
        }

        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let entryType = json["type"] as? String else {
                continue
            }

            guard Self.meaningfulTypes.contains(entryType) else {
                continue
            }

            return parseMessageState(from: json, entryType: entryType)
        }

        return .noMeaningfulMessage
    }

    private func parseMessageState(from json: [String: Any], entryType: String) -> LastLineState {
        if entryType == "user" {
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return .assistantWorking
            }
            return .userMessage
        }

        if entryType == "assistant" {
            if let message = json["message"] as? [String: Any] {
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" { return .assistantDone }
                return .assistantWorking
            }
            return .assistantWorking
        }

        return .noMeaningfulMessage
    }
}
