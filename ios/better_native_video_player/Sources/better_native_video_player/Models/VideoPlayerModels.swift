import Foundation
import AVFoundation

enum VideoPlayer {
    struct QualityLevel {
        let url: String
        let label: String
        let bitrate: Int
        let resolution: CGSize
    }
}
