import Foundation

/// One line in a night's log file (log.csv).
/// Format: ISO8601 time, kind, value, note
struct LogEvent: Identifiable {
    enum Kind: String {
        case start          // recording started, value = battery %
        case stop           // recording stopped by user, value = battery %
        case battery        // periodic battery reading, value = battery %
        case snore          // snore detected, value = confidence 0...1
        case loud           // loud sound (any kind), value = level dBFS
        case gap            // audio stopped arriving for a while, value = seconds missing
        case interruptBegin // system interrupted the audio session
        case interruptEnd   // interruption over, value = 1 if we resumed
        case segment        // a new audio file was started, note = file name
        case info
        case error
    }

    let id = UUID()
    let time: Date
    let kind: Kind
    let value: Double
    let note: String
}

/// Appends events to a CSV file. Each line is flushed right away, so the
/// log survives even if the app is killed during the night.
final class SessionLogWriter {
    let url: URL
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "log.writer")

    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func log(_ kind: LogEvent.Kind, _ value: Double = 0, _ note: String = "", at time: Date = Date()) {
        let cleanNote = note.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        let line = "\(SessionLogWriter.formatter.string(from: time)),\(kind.rawValue),\(value),\(cleanNote)\n"
        queue.async { [handle] in
            if let data = line.data(using: .utf8) {
                handle?.write(data)
            }
        }
    }

    func close() {
        queue.sync {
            try? handle?.synchronize()
            try? handle?.close()
        }
    }

    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func read(url: URL) -> [LogEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var events: [LogEvent] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3,
                  let time = formatter.date(from: parts[0]),
                  let kind = LogEvent.Kind(rawValue: parts[1]) else { continue }
            let value = Double(parts[2]) ?? 0
            let note = parts.count > 3 ? parts[3] : ""
            events.append(LogEvent(time: time, kind: kind, value: value, note: note))
        }
        return events
    }
}
