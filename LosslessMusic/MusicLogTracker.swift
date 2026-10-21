import Foundation

struct LosslessFormat: Equatable, Comparable, Sendable {
    let sampleRate: Double
    let bitDepth: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            ? lhs.bitDepth < rhs.bitDepth : lhs.sampleRate < rhs.sampleRate
    }

    var rateLabel: String {
        "\((sampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }
}

struct MusicLogEntry: Decodable, Sendable {
    let eventMessage: String
    let timestamp: String
    let processID: Int32
    let bootUUID: String
    let machTimestamp: UInt64
}

enum MusicPlaybackState: Equatable, Sendable {
    case unknown, playing, paused, stopped
}

struct MusicPlayback: Equatable, Sendable {
    var item: String?
    var format: LosslessFormat?
    var state: MusicPlaybackState = .unknown
    var isPlaying: Bool { state == .playing }
    var revision = 0
}

/// Full HLS lists and explicit ALAC lossless playback reports supply known formats.
/// Lower reports and temporary selections never lower an item's highest known format.
struct MusicLogTracker {
    private struct Block {
        var inAlternates = false
        var highest: LosslessFormat?
    }

    private(set) var playback = MusicPlayback()
    private var processID: Int32?
    private var bootUUID: String?
    private var player: String?
    private var engine: String?
    private var formats: [String: LosslessFormat] = [:]
    private var reportPlayers: [String: String] = [:]
    private var insertionOrder: [String] = []
    private var blocks: [String: Block] = [:]

    mutating func reset() {
        self = Self()
    }

    mutating func consume(_ entry: MusicLogEntry, historical: Bool = false) {
        if processID != entry.processID || (!entry.bootUUID.isEmpty && bootUUID != entry.bootUUID) {
            let revision = playback.revision + 1
            reset()
            playback.revision = revision
            processID = entry.processID
            bootUUID = entry.bootUUID
            MusicDiagnostics.log("PROCESS", "New Music process/boot; reset item cache", entry: entry, historical: historical)
        }
        let message = entry.eventMessage

        if message.contains("fasb_log:") {
            consumeAlternates(entry, historical: historical)
        } else if message.contains("fpfs_ReportAudioPlaybackThroughFigLog:") {
            consumeALACReport(entry, historical: historical)
        } else if message.contains("AVPlayer [itemDidBecomeCurrent]"),
                  let item = capture(#"current item:\S+ (I/[A-Z]+)\b"#, in: message),
                  let player = capture(#"- player:(P/[A-Z]+)\b"#, in: message) {
            MusicDiagnostics.log("TRACK", "\(playback.item ?? "nil") → \(item); cached=\(MusicDiagnostics.describe(format(for: item))) | \(message)", entry: entry, historical: historical)
            self.player = player
            engine = capture(#"\[PL:([^\]]+)\]"#, in: message)
            playback.item = item
            playback.format = format(for: item)
            playback.state = .unknown
            playback.revision += 1
        } else if message.contains("removed all player items"),
                  let source = capture(#"- player:(P/[A-Z]+)\b"#, in: message),
                  player == nil || source == player {
            MusicDiagnostics.log("QUEUE_CLEAR", "player=\(source); clear \(formats.count) item formats / \(blocks.count) pending blocks | \(message)", entry: entry, historical: historical)
            clearQueue()
        } else if message.contains("Received player event: playbackDidStart:"),
                  let item = capture(#"\b(I/[A-Z]+)\b"#, in: message),
                  let source = capture(#"\[PL:([^\]]+)\]"#, in: message),
                  (source == engine && item == playback.item) ||
                  (engine == nil && playback.item == nil && playback.state == .unknown) {
            // A resumed track need not repeat itemDidBecomeCurrent after the app launches.
            if engine == nil {
                engine = source
                playback.item = item
                playback.format = format(for: item)
                let matches = reportPlayers.filter { $0.key.hasPrefix(item + ".") }
                player = matches.count == 1 ? matches.first?.value : nil
                playback.revision += 1
                MusicDiagnostics.log("TRACK_RECOVERED", "item=\(item); recovered from playback start", entry: entry, historical: historical)
            }
            MusicDiagnostics.log("START", message, entry: entry, historical: historical)
            playback.state = .playing
        } else if matchesEngine(message) {
            if message.contains("Received player event: currentItemWillChange:"),
               message.contains(" -> nil") {
                MusicDiagnostics.log("CURRENT_CLEARED", message, entry: entry, historical: historical)
                playback.item = nil
                playback.format = nil
                playback.state = .stopped
                playback.revision += 1
            } else if message.contains("Received player event: playbackDidStop:"),
                      capture(#"\b(I/[A-Z]+)\b"#, in: message) == playback.item {
                MusicDiagnostics.log("STOP", "Cache retained | \(message)", entry: entry, historical: historical)
                playback.state = .paused
            } else if message.contains("PlayerController state did change:") {
                MusicDiagnostics.log("STATE", message, entry: entry, historical: historical)
                if message.contains(" -> paused") {
                    playback.state = .paused
                } else if message.contains(" -> idle") {
                    playback.state = .stopped
                }
            }
        }
    }

    /// Entries are merged and deduplicated in ascending order. Candidate blocks have
    /// already been rebuilt; resolve the current item's latest state backwards.
    mutating func restoreStartupState(from entries: [MusicLogEntry]) {
        guard let item = playback.item, engine != nil else {
            MusicDiagnostics.log("STARTUP_STATE", "state=\(playback.state); no current item in 15m history")
            return
        }
        playback.state = .unknown
        for entry in entries.reversed() {
            guard entry.processID == processID,
                  entry.bootUUID.isEmpty || entry.bootUUID == bootUUID,
                  matchesEngine(entry.eventMessage) else { continue }
            let message = entry.eventMessage
            if message.contains("Received player event: playbackDidStart:"),
               capture(#"\b(I/[A-Z]+)\b"#, in: message) == item {
                playback.state = .playing
            } else if message.contains("Received player event: playbackDidStop:"),
                      capture(#"\b(I/[A-Z]+)\b"#, in: message) == item {
                playback.state = .paused
            } else if message.contains("PlayerController state did change:"), message.contains(" -> paused") {
                playback.state = .paused
            } else if message.contains("PlayerController state did change:"), message.contains(" -> idle") {
                playback.state = .stopped
            } else if message.contains("AVPlayer [itemDidBecomeCurrent]") {
                // Do not inherit a state from before this item's current activation.
                break
            } else {
                continue
            }
            MusicDiagnostics.log("STARTUP_STATE", "item=\(item); state=\(playback.state); latest matching state", entry: entry, historical: true)
            return
        }
        MusicDiagnostics.log("STARTUP_STATE", "item=\(item); no conclusive start/stop for current activation in 15m history")
    }

    private func matchesEngine(_ message: String) -> Bool {
        guard let engine else { return false }
        return message.contains("[PL:\(engine)]")
    }

    private mutating func clearQueue() {
        formats.removeAll()
        reportPlayers.removeAll()
        insertionOrder.removeAll()
        blocks.removeAll()
        playback.item = nil
        playback.format = nil
        playback.state = .stopped
        playback.revision += 1
    }

    private mutating func consumeAlternates(_ entry: MusicLogEntry, historical: Bool) {
        let message = entry.eventMessage
        guard let identifier = capture(#"fasb_log: \[(0x[0-9a-f]+:I/[A-Z]+\.\d+)\]"#, in: message),
              let item = capture(#":(I/[A-Z]+\.\d+)\]"#, in: message) else { return }
        var block = blocks[identifier, default: Block()]
        for line in message.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "Alternates:" {
                block.inAlternates = true
            } else if text.hasPrefix("Filtered Alternates") {
                block.inAlternates = false
            }
            if block.inAlternates,
                      let value = capture(#"\[AudioGroup audio-alac-stereo-(\d+-\d+)\]"#, in: text) {
                let parts = value.split(separator: "-")
                if let rate = Double(parts[0]), let depth = UInt32(parts[1]), rate > 0, depth > 0 {
                    let format = LosslessFormat(sampleRate: rate, bitDepth: depth)
                    MusicDiagnostics.log("CANDIDATE", "item=\(item) ALAC \(MusicDiagnostics.describe(format))", entry: entry, historical: historical)
                    block.highest = max(block.highest ?? format, format)
                }
            }
        }
        if message.contains("LOG COMPLETE") {
            blocks.removeValue(forKey: identifier)
            guard let highest = block.highest else { return }
            recordFormat(highest, for: item, source: "fullAlternates", entry: entry, historical: historical)
        } else {
            if blocks.count > 128 { blocks.removeAll() }
            blocks[identifier] = block
        }
    }

    private mutating func consumeALACReport(_ entry: MusicLogEntry, historical: Bool) {
        let message = entry.eventMessage
        guard message.contains("[Rendition Lossless]"),
              capture(#"\[AudioFormat (qlac|alac)\b"#, in: message) != nil,
              let item = capture(#"\|(I/[A-Z]+\.\d+)>"#, in: message),
              let sourcePlayer = capture(#"\|(P/[A-Z]+)\]"#, in: message),
              let rateText = capture(#"\[SampleRate (\d+)\]"#, in: message),
              let depthText = capture(#"\[BitDepth (\d+)\]"#, in: message),
              let rate = Double(rateText), let depth = UInt32(depthText), rate > 0, depth > 0 else { return }
        reportPlayers[item] = sourcePlayer
        let format = LosslessFormat(sampleRate: rate, bitDepth: depth)
        MusicDiagnostics.log("ALAC_REPORT", "item=\(item); reported=\(MusicDiagnostics.describe(format))", entry: entry, historical: historical)
        recordFormat(format, for: item, source: "ALACPlaybackReport", entry: entry, historical: historical)
        if let current = playback.item, item.hasPrefix(current + "."), player == nil,
           formats.keys.filter({ $0.hasPrefix(current + ".") }).count == 1 {
            player = sourcePlayer
        }
    }

    private mutating func recordFormat(_ format: LosslessFormat, for item: String, source: String,
                                       entry: MusicLogEntry, historical: Bool) {
        let previous = formats[item]
        let retained = max(previous ?? format, format)
        MusicDiagnostics.log("FORMAT_MAX", "item=\(item) source=\(source) received=\(MusicDiagnostics.describe(format)) previous=\(MusicDiagnostics.describe(previous)) retained=\(MusicDiagnostics.describe(retained)) current=\(playback.item ?? "nil")", entry: entry, historical: historical)
        if previous == nil { insertionOrder.append(item) }
        formats[item] = retained
        if insertionOrder.count > 128 {
            let expired = insertionOrder.removeFirst()
            formats.removeValue(forKey: expired)
            reportPlayers.removeValue(forKey: expired)
        }
        if let current = playback.item { playback.format = self.format(for: current) }
    }

    private func format(for item: String) -> LosslessFormat? {
        let matches = formats.filter { $0.key.hasPrefix(item + ".") }
        // Do not silently merge multiple low-level instances sharing a short label.
        guard matches.count == 1 else { return nil }
        return matches.first?.value
    }
}

private func capture(_ pattern: String, in text: String) -> String? {
    guard let range = text.range(of: pattern, options: .regularExpression),
          let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(range, in: text)),
          let value = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[value])
}

// Live `log stream` can report an empty/missing bootUUID while persisted
// `log show` supplies it. Absence must not erase the process's replayed cache.
extension MusicLogEntry {
    private enum CodingKeys: String, CodingKey {
        case eventMessage, timestamp, processID, bootUUID, machTimestamp
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventMessage = try values.decode(String.self, forKey: .eventMessage)
        timestamp = try values.decode(String.self, forKey: .timestamp)
        processID = try values.decode(Int32.self, forKey: .processID)
        bootUUID = try values.decodeIfPresent(String.self, forKey: .bootUUID) ?? ""
        machTimestamp = try values.decode(UInt64.self, forKey: .machTimestamp)
    }
}
