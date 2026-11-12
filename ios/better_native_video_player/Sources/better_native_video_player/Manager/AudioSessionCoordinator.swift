import AVFoundation

/// Configures the shared audio session for playback without repeating work.
///
/// `setCategory` and `setActive(true)` are synchronous calls into the media
/// server and can block the main thread for tens of milliseconds. Playing a
/// video used to make both on every play, even when the session was already
/// set up that way. The play path now only sets the category when it differs
/// and only activates a session that isn't known to be active. Recovery paths
/// (foreground, background, interruption end) keep forcing activation with
/// `force: true`, exactly as before.
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    /// Whether this plugin activated the session and nothing has deactivated
    /// it since (an interruption or a media-services reset clears it).
    private(set) var isActive = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.isActive = false
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isActive = false
        }
    }

    /// Sets `.playback` / `.moviePlayback` with [options] unless the session
    /// already has exactly that configuration. Returns whether it changed, so
    /// the caller re-activates (a changed category, e.g. mixable to
    /// non-mixable, only takes full effect on activation).
    @discardableResult
    func ensurePlaybackCategory(options: AVAudioSession.CategoryOptions) throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playback && session.mode == .moviePlayback && session.categoryOptions == options {
            return false
        }
        try session.setCategory(.playback, mode: .moviePlayback, options: options)
        return true
    }

    /// Activates the session unless it is known to be active already.
    /// [force] always activates (used by the recovery paths).
    func activate(force: Bool = false) throws {
        if isActive && !force { return }
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        isActive = true
    }
}
