import Foundation

/// Plain stdout is visible in Xcode's console. Release builds omit diagnostic output.
enum MusicDiagnostics {
    static func log(_ category: String, _ message: @autoclosure () -> String,
                    entry: MusicLogEntry? = nil, historical: Bool = false) {
        #if DEBUG
        let received = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current))
        let source = entry.map {
            "[\(historical ? "REPLAY" : "LIVE")][event=\($0.timestamp)][pid=\($0.processID)]"
        } ?? ""
        print("[LosslessMusic][\(received)]\(source)[\(category)] \(message())")
        #endif
    }

    static func describe(_ format: LosslessFormat?) -> String {
        guard let format else { return "unknown" }
        return "\(format.bitDepth)-bit / \(format.rateLabel)"
    }
}
