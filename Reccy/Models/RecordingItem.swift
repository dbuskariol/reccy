import Foundation

struct RecordingItem: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let fileSize: Int64
    var duration: TimeInterval

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

    var formattedDuration: String {
        Duration.seconds(duration).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
