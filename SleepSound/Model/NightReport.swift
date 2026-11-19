import Foundation

/// A group of snore detections close together in time.
struct SnoreEpisode: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
    var hits: Int
    var maxConfidence: Double
}

struct AudioSegment {
    let fileName: String
    let start: Date
}

/// Everything we can say about one night, computed from its log file.
struct NightReport: Identifiable {
    let id: String          // folder name
    let folder: URL
    let events: [LogEvent]

    var start: Date?
    var end: Date?
    var stoppedByUser = false
    var batteryStart: Double?
    var batteryEnd: Double?
    var gaps: [LogEvent] = []
    var interruptions = 0
    var snoreHits = 0
    var episodes: [SnoreEpisode] = []
    var loudCount = 0
    var errors: [LogEvent] = []
    var segments: [AudioSegment] = []

    /// Episodes closer than this are merged into one.
    static let episodeMergeSeconds: TimeInterval = 30

    init(folder: URL) {
        self.folder = folder
        self.id = folder.lastPathComponent
        self.events = SessionLogWriter.read(url: folder.appendingPathComponent("log.csv"))

        start = events.first(where: { $0.kind == .start })?.time ?? events.first?.time
        end = events.last?.time

        for e in events {
            switch e.kind {
            case .start:
                batteryStart = e.value >= 0 ? e.value : nil
                batteryEnd = batteryStart
            case .battery:
                if e.value >= 0 { batteryEnd = e.value }
            case .stop:
                stoppedByUser = true
                if e.value >= 0 { batteryEnd = e.value }
            case .gap:
                gaps.append(e)
            case .interruptBegin:
                interruptions += 1
            case .snore:
                snoreHits += 1
                if var last = episodes.last, e.time.timeIntervalSince(last.end) <= Self.episodeMergeSeconds {
                    last.end = e.time
                    last.hits += 1
                    last.maxConfidence = max(last.maxConfidence, e.value)
                    episodes[episodes.count - 1] = last
                } else {
                    episodes.append(SnoreEpisode(start: e.time, end: e.time, hits: 1, maxConfidence: e.value))
                }
            case .loud:
                loudCount += 1
            case .error:
                errors.append(e)
            case .segment:
                segments.append(AudioSegment(fileName: e.note, start: e.time))
            default:
                break
            }
        }
    }

    var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return end.timeIntervalSince(start)
    }

    var missingSeconds: TimeInterval {
        gaps.reduce(0) { $0 + $1.value }
    }

    var batteryUsed: Double? {
        guard let batteryStart, let batteryEnd else { return nil }
        return batteryStart - batteryEnd
    }

    var batteryPerHour: Double? {
        guard let used = batteryUsed, duration > 600 else { return nil }
        return used / (duration / 3600)
    }

    var snoreMinutes: Double {
        episodes.reduce(0) { $0 + max($1.end.timeIntervalSince($1.start), 1) } / 60
    }

    /// Finds which audio file contains the given moment and the offset inside it.
    func audioPosition(for time: Date) -> (URL, TimeInterval)? {
        guard let seg = segments.last(where: { $0.start <= time }) ?? segments.first else { return nil }
        let url = folder.appendingPathComponent(seg.fileName)
        return (url, max(0, time.timeIntervalSince(seg.start)))
    }

    var folderSizeMB: Double {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Double(bytes) / 1_048_576
    }
}

enum SessionStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Nights", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newNightFolder() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let dir = root.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func allNights() -> [NightReport] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { NightReport(folder: $0) }
    }

    static func delete(_ night: NightReport) {
        try? FileManager.default.removeItem(at: night.folder)
    }
}
