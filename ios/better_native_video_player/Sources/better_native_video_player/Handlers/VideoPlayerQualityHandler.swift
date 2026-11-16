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

            var qualities: [VideoPlayer.QualityLevel] = []
            let lines = playlist.components(separatedBy: "\n")
            var lastBitrate: Int?
            var lastResolution: String?
            
            for line in lines {
                if line.contains("#EXT-X-STREAM-INF") {
                    // Extract resolution
                    if let resMatch = line.range(of: "RESOLUTION=\\d+x\\d+", options: .regularExpression) {
                        lastResolution = String(line[resMatch]).replacingOccurrences(of: "RESOLUTION=", with: "")
                    }
                    
                    // Extract bitrate
                    if let bitrateMatch = line.range(of: "BANDWIDTH=\\d+", options: .regularExpression) {
                        let bitrateStr = String(line[bitrateMatch]).replacingOccurrences(of: "BANDWIDTH=", with: "")
                        lastBitrate = Int(bitrateStr)
                    }
                } else if line.hasSuffix(".m3u8") {
                    // Resolve relative URLs against the base URL
                    let qualityUrl: String
                    if line.hasPrefix("http://") || line.hasPrefix("https://") {
                        qualityUrl = line
                    } else {
                        let baseUrl = url.deletingLastPathComponent()
                        if let resolvedUrl = URL(string: line, relativeTo: baseUrl)?.absoluteString {
                            qualityUrl = resolvedUrl
                        } else {
                            qualityUrl = line
                        }
                    }
                    
                    if let resolution = lastResolution {
                        let components = resolution.components(separatedBy: "x")
                        if components.count == 2,
                           let width = Int(components[0]),
                           let height = Int(components[1]) {
                            qualities.append(VideoPlayer.QualityLevel(
                                url: qualityUrl,
                                label: resolution,
                                bitrate: lastBitrate ?? 0,
                                resolution: CGSize(width: width, height: height)
                            ))
                        }
                    }
                }
            }
            
            // Sort qualities by resolution height (ascending)
            let sortedQualities = qualities.sorted { $0.resolution.height < $1.resolution.height }
            DispatchQueue.main.async { completion(sortedQualities) }
        }.resume()
    }
}