import AVFoundation
import Combine
import Foundation

/// Plays back a short piece of a night's recording on the watch speaker.
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?

    /// Plays `length` seconds starting a few seconds before `time`.
    func play(night: NightReport, at time: Date, id: UUID, length: TimeInterval = 15) {
        stop()
        guard let position = night.audioPosition(for: time.addingTimeInterval(-3)) else {
            error = "找不到这段录音"
            return
        }
        let (url, offset) = position
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.currentTime = min(offset, max(0, p.duration - 1))
            p.play()
            player = p
            playingID = id
            error = nil
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + length, execute: work)
        } catch {
            self.error = "播放失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}
