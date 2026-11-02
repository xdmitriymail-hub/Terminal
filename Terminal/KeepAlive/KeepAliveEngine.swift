import AVFoundation
import Combine
import Foundation

/// Best-effort background keep-alive: an inaudible looped buffer keeps
/// the process's sockets alive while the app is backgrounded. It is an
/// explicit opt-in experiment — iOS offers no hard guarantee, and the
/// engine exposes its real state instead of pretending otherwise. The
/// session mixes with other apps: the user's music keeps playing, we
/// never take over Now Playing, and VPN is untouched.
@MainActor
final class KeepAliveEngine: ObservableObject {
    @Published private(set) var isRunning = false
    /// The system interrupted our audio session (call, Siri, alarm).
    /// Running again is only attempted once it ends with shouldResume.
    @Published private(set) var isInterrupted = false
    /// Last start/stop failure — surfaced so the UI can be honest about
    /// keep-alive being best-effort, not guaranteed.
    @Published private(set) var failure: String?

    private let engine = AVAudioEngine()
    private var player: AVAudioPlayerNode?
    private var enabled = false
    /// Real activity: live sessions AND in-flight transfers, set by the
    /// owner. The stream only runs while something actually needs it —
    /// burning battery for dead tabs is never justified.
    private var liveSessions = 0
    private var activeTransfers = 0
    private var observerTokens: [NSObjectProtocol] = []

    private var wantsRun: Bool {
        enabled && (liveSessions > 0 || activeTransfers > 0)
    }

    enum KeepAliveError: Error {
        case formatUnavailable
        case bufferUnavailable
    }

    init() {
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartIfNeeded() }
        })
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Detaches every observer — callable teardown for tests/lifecycle.
    func invalidate() {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens.removeAll()
        stop()
    }

    // MARK: - Inputs

    /// Backwards-compatible session signal. Prefer
    /// `updateActivity(liveSessions:activeTransfers:)` — it is honest
    /// about *live* sessions (connecting/online/reconnecting) and
    /// counts transfers too.
    func setHasSessions(_ value: Bool) {
        updateActivity(liveSessions: value ? max(1, liveSessions) : 0, activeTransfers: activeTransfers)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        reconcile()
    }

    /// The activity contract: how many sessions are doing network work
    /// right now (connecting, online or reconnecting — not offline or
    /// failed) plus how many file transfers are in flight.
    func updateActivity(liveSessions: Int, activeTransfers: Int) {
        self.liveSessions = max(0, liveSessions)
        self.activeTransfers = max(0, activeTransfers)
        reconcile()
    }

    private func reconcile() {
        if wantsRun { start() } else { stop() }
    }

    // MARK: - Engine

    private func start() {
        guard wantsRun, !isRunning, !isInterrupted else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try configureEngine()
            isRunning = true
            failure = nil
        } catch {
            // Roll back the session to how we found it: a partially
            // configured engine with an active audio session is worse
            // than none at all.
            player?.stop()
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.ambient)
            isRunning = false
            failure = "Background keep-alive unavailable"
        }
    }

    /// The node→mixer wiring and the looped buffer are one-time graph
    /// setup — connecting a node twice throws, so restarts after a
    /// route change only restart the engine and resume the player.
    private var graphConfigured = false

    private func configureEngine() throws {
        if player == nil {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            player = node
        }
        guard let player else { throw KeepAliveError.bufferUnavailable }

        if !graphConfigured {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else {
                throw KeepAliveError.formatUnavailable
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0

            // A looped buffer of pure silence — the cheapest possible
            // stream. Scheduled once: it loops for the node's lifetime.
            let frameCount = AVAudioFrameCount(48000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw KeepAliveError.bufferUnavailable
            }
            buffer.frameLength = frameCount
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            graphConfigured = true
        }

        try engine.start()
        player.play()
    }

    private func stop() {
        player?.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system took the audio session — reflect that we're
            // interrupted rather than pretending to still run.
            isInterrupted = true
            isRunning = false
        case .ended:
            isInterrupted = false
            // Resume quietly once the interrupting app is done — but only
            // when the system tells us we're allowed back on the session.
            let shouldResume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? true
            if shouldResume { reconcile() }
        @unknown default:
            break
        }
    }

    private func restartIfNeeded() {
        guard enabled, wantsRun else { return }
        player?.stop()
        engine.stop()
        isRunning = false
        start()
    }
}
