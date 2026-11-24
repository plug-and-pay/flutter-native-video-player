import Foundation
import AVFoundation

class VideoPlayerQualityHandler {
    /// Calls [completion] on the main queue: callers update view and
    /// SharedPlayerManager state, which is main-thread only.
    /// [headers] are the ones the video was loaded with, so streams that need
    /// a Referer or token get a quality list too.
    static func fetchHLSQualities(from url: URL, headers: [String: String]? = nil, completion: @escaping ([VideoPlayer.QualityLevel]) -> Void) {
        var request = URLRequest(url: url)
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data,
                  let playlist = String(data: data, encoding: .utf8)
            else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            DispatchQueue.main.async { completion(parseMasterPlaylist(playlist, baseUrl: url)) }
        }.resume()
    }

    /// The variants of an HLS master playlist, sorted by height (ascending).
    /// A variant's URI is the first line after its `#EXT-X-STREAM-INF` tag
    /// that is not a tag or comment (RFC 8216 §4.3.4.2), so signed variant
    /// URLs (`video.m3u8?token=…`) and CRLF playlists count too. Variants
    /// without a RESOLUTION (audio-only) are left out.
    static func parseMasterPlaylist(_ playlist: String, baseUrl: URL) -> [VideoPlayer.QualityLevel] {
        var qualities: [VideoPlayer.QualityLevel] = []
        var pendingBitrate: Int?
        var pendingResolution: CGSize?
        var awaitingUri = false

        for rawLine in playlist.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-STREAM-INF") {
                awaitingUri = true
                pendingResolution = nil
                pendingBitrate = nil
                if let match = line.range(of: "RESOLUTION=\\d+x\\d+", options: .regularExpression) {
                    let parts = line[match].dropFirst("RESOLUTION=".count).split(separator: "x")
                    if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                        pendingResolution = CGSize(width: width, height: height)
                    }
                }
                // AVERAGE-BANDWIDTH also contains "BANDWIDTH=": anchor on the
                // attribute boundary.
                if let match = line.range(of: "(:|,)BANDWIDTH=\\d+", options: .regularExpression) {
                    pendingBitrate = Int(line[match].drop { !$0.isNumber })
                }
                continue
            }

            if line.hasPrefix("#") || !awaitingUri { continue }
            awaitingUri = false

            guard let resolution = pendingResolution,
                  let qualityUrl = URL(string: line, relativeTo: baseUrl)?.absoluteString
            else { continue }

            let label = "\(Int(resolution.width))x\(Int(resolution.height))"
            qualities.append(VideoPlayer.QualityLevel(
                url: qualityUrl,
                label: label,
                bitrate: pendingBitrate ?? 0,
                resolution: resolution
            ))
        }

        return qualities.sorted { $0.resolution.height < $1.resolution.height }
    }
}
