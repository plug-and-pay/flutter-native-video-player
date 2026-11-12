import AVFoundation

/// Backs NativeVideoPlayerPreloader on iOS: loads the assets of the few
/// videos around the current reel in the background (for HLS: the master and
/// media playlists; for files: the header), so a later load() of the same URL
/// starts with that already done.
///
/// Only the AVURLAsset is handed over. An AVPlayerItem can't move between
/// players (AVFoundation raises an exception), and creating a hidden player
/// per neighbour would cost decoders and memory, so no segments are buffered
/// ahead on iOS.
///
/// Main thread only. Bounded: at most `maxEntries` window items, plus items
/// that left the window in the last few seconds (released after that).
final class VideoPreloadPool {
    static let shared = VideoPreloadPool()

    static let maxEntries = 3

    /// The keys AVPlayerItem would otherwise load itself on startup.
    private static let assetKeys = ["playable", "duration", "tracks"]

    private final class Entry {
        let headers: [String: String]?
        let asset: AVURLAsset

        init(url: URL, headers: [String: String]?) {
            self.headers = headers
            if let headers = headers, !headers.isEmpty {
                asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            } else {
                asset = AVURLAsset(url: url)
            }
            asset.loadValuesAsynchronously(forKeys: VideoPreloadPool.assetKeys, completionHandler: nil)
        }

        func release() {
            asset.cancelLoading()
        }

        var failed: Bool {
            var error: NSError?
            return asset.statusOfValue(forKey: "playable", error: &error) == .failed
        }
    }

    private var entries: [String: Entry] = [:]

    /// Items that just left the window, kept for `leavingGraceSeconds`: the
    /// window moves on the swipe, before the new current page's load() can
    /// take its asset (the current item is never in the window).
    private var leaving: [String: (entry: Entry, release: DispatchWorkItem)] = [:]

    private static let leavingGraceSeconds: Double = 3

    var count: Int { entries.count }

    /// Makes the pool hold exactly `items` (url + optional headers).
    func setWindow(_ items: [(url: String, headers: [String: String]?)]) {
        let limited = Array(items.prefix(VideoPreloadPool.maxEntries))
        let wanted = Set(limited.map { $0.url })
        for (key, entry) in entries where !wanted.contains(key) {
            entries.removeValue(forKey: key)
            scheduleRelease(of: entry, key: key)
        }
        for item in limited {
            if let back = leaving.removeValue(forKey: item.url) {
                // Came back into the window before it was released.
                back.release.cancel()
                if back.entry.headers == item.headers {
                    entries[item.url] = back.entry
                    continue
                }
                back.entry.release()
            }
            if let existing = entries[item.url] {
                if existing.headers == item.headers { continue }
                existing.release()
                entries.removeValue(forKey: item.url)
            }
            guard let url = URL(string: item.url) else { continue }
            entries[item.url] = Entry(url: url, headers: item.headers)
        }
        npLog("🎬 Preload window: \(entries.count) item(s), \(leaving.count) leaving")
    }

    private func scheduleRelease(of entry: Entry, key: String) {
        leaving[key]?.release.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let gone = self.leaving.removeValue(forKey: key) else { return }
            gone.entry.release()
        }
        leaving[key] = (entry: entry, release: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + VideoPreloadPool.leavingGraceSeconds, execute: work)
    }

    /// Hands the preloaded asset for `url` to the caller and removes it from
    /// the pool. Nil when nothing usable is preloaded: unknown URL, different
    /// headers, or a failed asset.
    func take(url: String, headers: [String: String]?) -> AVURLAsset? {
        let entry: Entry
        if let current = entries.removeValue(forKey: url) {
            entry = current
        } else if let left = leaving.removeValue(forKey: url) {
            left.release.cancel()
            entry = left.entry
        } else {
            return nil
        }
        guard (entry.headers ?? [:]) == (headers ?? [:]), !entry.failed else {
            entry.release()
            return nil
        }
        npLog("🎬 Preload hit for \(url)")
        return entry.asset
    }

    func clear() {
        for entry in entries.values { entry.release() }
        entries.removeAll()
        for left in leaving.values {
            left.release.cancel()
            left.entry.release()
        }
        leaving.removeAll()
    }
}
