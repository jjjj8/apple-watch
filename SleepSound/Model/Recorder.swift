import AVFoundation
import Combine
import CoreMedia
import Foundation
import SoundAnalysis
import WatchKit

/// Records the microphone all night, saves compressed audio in 15-minute files,
/// runs Apple's built-in sound classifier to spot snoring, and writes
/// everything that happens (battery, interruptions, gaps) to a log file.
final class Recorder: NSObject, ObservableObject {
    // MARK: Published state for the UI (always updated on the main thread)
    @Published private(set) var isRecording = false
    @Published private(set) var startDate: Date?
    @Published private(set) var snoreCount = 0
    @Published private(set) var interruptionCount = 0
    @Published private(set) var gapCount = 0
    @Published private(set) var levelDB: Float = -160
    @Published private(set) var lastError: String?
    @Published private(set) var classifierAvailable = true
    @Published var permissionDenied = false
    /// Battery saver: only analyze and save audio around sounds louder than the
    /// room's background noise, instead of the whole night.
    @Published var saverMode: Bool = UserDefaults.standard.object(forKey: "saverMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saverMode, forKey: "saverMode") }
    }

    // MARK: Tunables
    static let snoreThreshold: Double = 0.5
    static let loudThresholdDB: Float = -25
    static let segmentLength: TimeInterval = 15 * 60
    static let batteryLogInterval: TimeInterval = 5 * 60
    static let gapThreshold: TimeInterval = 5
    static let fileSampleRate: Double = 16_000
    /// Saver mode: a sound must be this many dB above the background to count.
    static let triggerAboveFloorDB: Float = 8
    static let triggerMinimumDB: Float = -58
    /// Saver mode: keep analyzing/recording this long after the last loud buffer.
    static let activeHold: TimeInterval = 8
    /// Saver mode: audio kept from before the trigger, so the clip starts early enough.
    static let preRollSeconds: Double = 4
    static let maxClipLength: TimeInterval = 120

    // MARK: Audio objects
    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private var log: SessionLogWriter?
    private var folder: URL?
    private var inputFormat: AVAudioFormat?

    // Only touched on `processing` queue
    private let processing = DispatchQueue(label: "audio.processing", qos: .userInitiated)
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var segmentIndex = 0
    private var segmentStart = Date.distantPast
    private var lastBufferTime: Date?
    private var lastBatteryLog = Date.distantPast
    private var lastLoudLog = Date.distantPast
    private var lastLevelPublish = Date.distantPast
    private var lastSnoreLog = Date.distantPast
    private var saverActive = false          // copy of saverMode for this night
    private var noiseFloorDB: Float = -60
    private var activeUntil = Date.distantPast
    private var clipOpen = false
    private var preRoll: [(buffer: AVAudioPCMBuffer, time: AVAudioFramePosition)] = []
    private var preRollFrames: AVAudioFrameCount = 0
    private var clipCount = 0

    private var observers: [NSObjectProtocol] = []

    // MARK: - Start / stop

    @MainActor
    func start() {
        guard !isRecording else { return }
        lastError = nil
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    MainActor.assumeIsolated { self.startAfterPermission() }
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    @MainActor
    private func startAfterPermission() {
        let folder = SessionStore.newNightFolder()
        let log = SessionLogWriter(url: folder.appendingPathComponent("log.csv"))
        self.folder = folder
        self.log = log

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [])
            // Ask for a low sample rate: less data to process all night.
            try? session.setPreferredSampleRate(Self.fileSampleRate)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "SleepSound", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风格式无效 (\(format))"])
            }
            inputFormat = format
            log.log(.info, format.sampleRate, "mic format ch=\(format.channelCount)")

            setUpClassifier(format: format, log: log)

            let saver = saverMode
            log.log(.info, saver ? 1 : 0, saver ? "mode=saver" : "mode=full")
            processing.sync {
                self.saverActive = saver
                self.segmentIndex = 0
                self.clipCount = 0
                self.clipOpen = false
                self.preRoll = []
                self.preRollFrames = 0
                self.noiseFloorDB = -60
                self.activeUntil = .distantPast
                self.lastBufferTime = nil
                self.lastBatteryLog = Date()
                if !saver { self.openNewSegment(now: Date()) }
            }

            input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, time in
                guard let self else { return }
                self.processing.async { self.handle(buffer: buffer, time: time) }
            }

            engine.prepare()
            try engine.start()
        } catch {
            log.log(.error, 0, "start failed: \(error.localizedDescription)")
            log.close()
            lastError = error.localizedDescription
            engine.inputNode.removeTap(onBus: 0)
            return
        }

        addObservers()
        log.log(.start, Self.batteryPercent())
        startDate = Date()
        snoreCount = 0
        interruptionCount = 0
        gapCount = 0
        isRecording = true
    }

    @MainActor
    func stop() {
        guard isRecording else { return }
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        processing.sync {
            if let last = self.lastBufferTime {
                let missing = Date().timeIntervalSince(last)
                if missing > Self.gapThreshold {
                    self.log?.log(.gap, missing, "no audio until stop", at: last)
                }
            }
            self.analyzer?.completeAnalysis()
            self.audioFile = nil   // releasing the file finalizes it
            self.converter = nil
        }
        analyzer = nil

        log?.log(.stop, Self.batteryPercent())
        log?.close()
        log = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
    }

    /// Lets the UI write notes into the log (e.g. app went to background).
    func note(_ text: String) {
        log?.log(.info, 0, text)
    }

    // MARK: - Classifier

    private func setUpClassifier(format: AVAudioFormat, log: SessionLogWriter) {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // One analysis every ~3 seconds is enough for snoring and saves battery.
            let desired = CMTime(seconds: 3, preferredTimescale: 1000)
            switch request.windowDurationConstraint {
            case .durationRange(let range):
                if CMTimeRangeContainsTime(range, time: desired) {
                    request.windowDuration = desired
                }
            case .enumeratedDurations(let options):
                if let best = options.min(by: { abs($0.seconds - 3) < abs($1.seconds - 3) }) {
                    request.windowDuration = best
                }
            @unknown default:
                break
            }
            request.overlapFactor = 0
            try analyzer.add(request, withObserver: self)
            log.log(.info, request.windowDuration.seconds, "classifier window seconds")
            self.analyzer = analyzer
            DispatchQueue.main.async { self.classifierAvailable = true }
        } catch {
            log.log(.error, 0, "classifier unavailable: \(error.localizedDescription)")
            self.analyzer = nil
            DispatchQueue.main.async { self.classifierAvailable = false }
        }
    }

    // MARK: - Audio processing (runs on `processing` queue)

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let now = Date()

        // 1. Detect holes in the audio stream (system paused us).
        if let last = lastBufferTime {
            let missing = now.timeIntervalSince(last)
            if missing > Self.gapThreshold {
                log?.log(.gap, missing, "audio resumed", at: last)
                DispatchQueue.main.async { self.gapCount += 1 }
            }
        }
        lastBufferTime = now

        let db = Self.rmsDB(buffer)
        if db > Self.loudThresholdDB, now.timeIntervalSince(lastLoudLog) > 10 {
            lastLoudLog = now
            log?.log(.loud, Double(db))
        }
        if now.timeIntervalSince(lastLevelPublish) > 2 {
            lastLevelPublish = now
            DispatchQueue.main.async { self.levelDB = db }
        }

        if saverActive {
            handleSaver(buffer: buffer, time: time, db: db, now: now)
        } else {
            // Full mode: analyze everything, save everything (new file every 15 min).
            analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
            if now.timeIntervalSince(segmentStart) >= Self.segmentLength {
                openNewSegment(now: now)
            }
            write(buffer)
        }

        // 5. Battery every 5 minutes.
        if now.timeIntervalSince(lastBatteryLog) >= Self.batteryLogInterval {
            lastBatteryLog = now
            let log = self.log
            DispatchQueue.main.async {
                MainActor.assumeIsolated { log?.log(.battery, Self.batteryPercent()) }
            }
        }
    }

    /// Battery saver: stay mostly idle, wake up the classifier and the audio file
    /// only while something louder than the room's background noise is happening.
    private func handleSaver(buffer: AVAudioPCMBuffer, time: AVAudioTime, db: Float, now: Date) {
        // Track the background noise level: drops fast, rises slowly.
        if db < noiseFloorDB {
            noiseFloorDB = 0.8 * noiseFloorDB + 0.2 * db
        } else {
            noiseFloorDB = 0.995 * noiseFloorDB + 0.005 * db
        }
        let trigger = max(noiseFloorDB + Self.triggerAboveFloorDB, Self.triggerMinimumDB)

        if db > trigger {
            if !clipOpen {
                openClip(now: now)
            }
            activeUntil = now.addingTimeInterval(Self.activeHold)
        }

        if clipOpen, now < activeUntil, now.timeIntervalSince(segmentStart) < Self.maxClipLength {
            analyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
            write(buffer)
            return
        }

        if clipOpen {
            closeClip()
        }
        // Idle: just remember the last few seconds in case a sound starts.
        if let copy = Self.copy(buffer) {
            preRoll.append((copy, time.sampleTime))
            preRollFrames += copy.frameLength
            let limit = AVAudioFrameCount(Self.preRollSeconds * buffer.format.sampleRate)
            while preRollFrames > limit, preRoll.count > 1 {
                preRollFrames -= preRoll.removeFirst().buffer.frameLength
            }
        }
    }

    private func openClip(now: Date) {
        let preRollDuration = Double(preRollFrames) / (inputFormat?.sampleRate ?? Self.fileSampleRate)
        openNewSegment(now: now.addingTimeInterval(-preRollDuration), prefix: "clip")
        converter?.reset()
        clipOpen = true
        clipCount += 1
        for item in preRoll {
            analyzer?.analyze(item.buffer, atAudioFramePosition: item.time)
            write(item.buffer)
        }
        preRoll = []
        preRollFrames = 0
    }

    private func closeClip() {
        audioFile = nil     // finalizes the m4a
        converter = nil
        clipOpen = false
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for ch in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch], bytes)
        }
        return out
    }

    private func openNewSegment(now: Date, prefix: String = "audio") {
        audioFile = nil
        converter = nil
        guard let folder, let inputFormat else { return }
        let name = String(format: "\(prefix)-%04d.m4a", segmentIndex)
        segmentIndex += 1
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.fileSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name),
                                       settings: settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            converter = AVAudioConverter(from: inputFormat, to: file.processingFormat)
            audioFile = file
            segmentStart = now
            log?.log(.segment, 0, name, at: now)
        } catch {
            log?.log(.error, 0, "cannot create audio file: \(error.localizedDescription)")
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file = audioFile, let converter else { return }
        let outFormat = file.processingFormat
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log?.log(.error, 0, "convert: \(error?.localizedDescription ?? "?")")
            return
        }
        guard out.frameLength > 0 else { return }
        do {
            try file.write(from: out)
        } catch {
            log?.log(.error, 0, "write: \(error.localizedDescription)")
        }
    }

    private static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let samples = data[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(n))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    @MainActor
    static func batteryPercent() -> Double {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        return level < 0 ? -1 : Double((level * 100).rounded())
    }

    // MARK: - System notifications

    private func addObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log?.log(.info, 0, "engine configuration changed")
            self.restartEngine(reason: "config change")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.log?.log(.error, 0, "media services were reset")
            self?.restartEngine(reason: "media reset")
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            log?.log(.interruptBegin, 0, "system interruption")
            interruptionCount += 1
        case .ended:
            let ok = restartEngine(reason: "after interruption")
            log?.log(.interruptEnd, ok ? 1 : 0)
        @unknown default:
            break
        }
    }

    @discardableResult
    private func restartEngine(reason: String) -> Bool {
        guard isRecording, !engine.isRunning else { return engine.isRunning }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            log?.log(.info, 1, "engine restarted (\(reason))")
            return true
        } catch {
            log?.log(.error, 0, "restart failed (\(reason)): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - SoundAnalysis results

extension Recorder: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let snore = result.classification(forIdentifier: "snoring") else { return }
        guard snore.confidence >= Self.snoreThreshold else { return }
        let now = Date()
        lastSnoreLog = now
        log?.log(.snore, (snore.confidence * 100).rounded() / 100)
        DispatchQueue.main.async { self.snoreCount += 1 }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        log?.log(.error, 0, "classifier failed: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
