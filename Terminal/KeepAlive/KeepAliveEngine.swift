import Foundation
import AVFoundation

/// Keeps the process (and its sockets) alive in the background by playing an
/// inaudible audio stream. The session mixes with other apps: the user's
/// music keeps playing, we never take over Now Playing, and VPN is untouched.
@MainActor
final class KeepAliveEngine: ObservableObject {
    @Published private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var player: AVAudioPlayerNode?
    private var enabled = false

    init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartIfNeeded() }
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try configureEngine()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func configureEngine() throws {
        if player == nil {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            player = node
        }
        guard let player else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        // A looped buffer of pure silence — the cheapest possible stream.
        let frameCount = AVAudioFrameCount(48000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        buffer.floatChannelData?.pointee.update(repeating: 0, count: Int(frameCount))

        try engine.start()
        player.play()
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }

    private func stop() {
        player?.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func handleInterruption(_ note: Notification) {
        guard enabled,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            break
        case .ended:
            // Resume quietly once the interrupting app is done — but only
            // when the system tells us we're allowed back on the session.
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
            if shouldResume { restartIfNeeded() }
        @unknown default:
            break
        }
    }

    private func restartIfNeeded() {
        guard enabled else { return }
        player?.stop()
        engine.stop()
        isRunning = false
        start()
    }
}
