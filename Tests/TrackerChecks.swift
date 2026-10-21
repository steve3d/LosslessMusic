import Foundation

@main
struct TrackerChecks {
    static func main() throws {
        var tracker = MusicLogTracker()
        var sequence: UInt64 = 0
        func entry(_ message: String, pid: Int32 = 3108, boot: String = "test-boot") -> MusicLogEntry {
            sequence += 1
            return MusicLogEntry(eventMessage: message, timestamp: "test", processID: pid,
                                 bootUUID: boot, machTimestamp: sequence)
        }
        func current(_ item: String, player: String = "P/NA") -> String {
            "[PL:test] AVPlayer [itemDidBecomeCurrent] - current item:1::2 \(item) 0x1 - player:\(player) 0x2"
        }
        func candidates(_ item: String, _ formats: [(Int, Int)]) -> String {
            "fasb_log: [0x123:\(item).01]\nAlternates:\n{\n" + formats.map {
                "[AudioGroup audio-alac-stereo-\($0.0)-\($0.1)]"
            }.joined(separator: "\n") + "\n}\nFiltered Alternates[1]:\n{\n[AudioGroup audio-alac-stereo-48000-24]\n}\nLOG COMPLETE"
        }
        let high = LosslessFormat(sampleRate: 192_000, bitDepth: 24)
        let low = LosslessFormat(sampleRate: 44_100, bitDepth: 16)
        precondition(tracker.playback.state == .unknown)
        tracker.consume(entry(current("I/AAA")))
        precondition(tracker.playback.state == .unknown, "Current item alone does not confirm playback started")
        tracker.consume(entry("[PL:test] Received player event: playbackDidStart: I/AAA"))
        precondition(tracker.playback.isPlaying && tracker.playback.format == nil)
        tracker.consume(entry("fasb_log: [0x123:I/AAA.01]\nAlternates:\n{\n[AudioGroup audio-alac-stereo-192000-24]"))
        precondition(tracker.playback.format == nil, "Do not commit an incomplete list")
        tracker.consume(entry("fasb_log: [0x123:I/AAA.01]\n}\nFiltered Alternates[1]:\n{\n[AudioGroup audio-alac-stereo-48000-24]\n}\nLOG COMPLETE"))
        precondition(tracker.playback.format == high, "Use full candidates, not filtered selection")
        tracker.consume(entry("[PL:test] Received player event: playbackDidStart: I/AAA", boot: ""))
        precondition(tracker.playback.format == high, "An empty live bootUUID must not reset replayed state")
        let missingBoot = Data(#"{"eventMessage":"test","timestamp":"test","processID":3108,"machTimestamp":1}"#.utf8)
        let decoded = try JSONDecoder().decode(MusicLogEntry.self, from: missingBoot)
        precondition(decoded.bootUUID.isEmpty)
        tracker.consume(entry(candidates("I/BBB", [(44_100, 16)])))
        precondition(tracker.playback.format == high, "Preloading must not change the current target")
        tracker.consume(entry(candidates("I/AAA", [(48_000, 24)])))
        precondition(tracker.playback.format == high, "Do not downgrade the same item")
        tracker.consume(entry("[PL:test] Received player event: playbackDidStop: I/BBB"))
        precondition(tracker.playback.isPlaying, "An old/unrelated item's stop must not pause current")
        tracker.consume(entry("[PL:test] Received player event: playbackDidStop: I/AAA"))
        precondition(tracker.playback.state == .paused && tracker.playback.format == high)
        tracker.consume(entry("[PL:test] Received player event: playbackDidStart: I/AAA"))
        precondition(tracker.playback.isPlaying && tracker.playback.format == high)
        tracker.consume(entry(current("I/BBB")))
        precondition(tracker.playback.format == low, "A new item may lower the target")
        tracker.consume(entry("Queue->Player synchronization completed [removed all player items] - player:P/ZZ 0x2"))
        precondition(tracker.playback.item == "I/BBB", "Another player's clear must not erase this queue")
        tracker.consume(entry("Queue->Player synchronization completed [removed all player items] - player:P/NA 0x2"))
        precondition(tracker.playback.item == nil && tracker.playback.format == nil && tracker.playback.state == .stopped)
        tracker.consume(entry(current("I/AAA")))
        precondition(tracker.playback.format == nil, "Cleared candidates must not survive queue reset")
        tracker.consume(entry(candidates("I/AAA", [(192_000, 24)])))
        tracker.consume(entry(current("I/AAA"), pid: 99))
        precondition(tracker.playback.format == nil, "A new Music process must not inherit formats")
        func startup(_ messages: [String]) -> MusicPlayback {
            var restored = MusicLogTracker()
            let entries = messages.map { entry($0) }
            for value in entries { restored.consume(value, historical: true) }
            restored.restoreStartupState(from: entries)
            return restored.playback
        }
        let playing = [current("I/AAA"), candidates("I/AAA", [(192_000, 24)]),
                       "[PL:test] Received player event: playbackDidStart: I/AAA"]
        let stop = "[PL:test] Received player event: playbackDidStop: I/AAA"
        precondition(startup(playing).isPlaying && startup(playing).format == high)
        precondition(startup(playing + [stop]).state == .paused, "Latest stop blocks startup switching")
        precondition(startup(playing + [stop, playing[2]]).isPlaying, "Resume after stop is playing")
        precondition(startup(playing + ["[PL:test] Received player event: playbackDidStop: I/BBB"]).isPlaying)
        precondition(startup(playing + ["[PL:other] Received player event: playbackDidStop: I/AAA"]).isPlaying)
        precondition(startup(playing + [current("I/BBB")]).state == .unknown, "Do not reuse the prior activation's start")
        precondition(startup([candidates("I/AAA", [(192_000, 24)])]).state == .unknown, "Formats alone do not imply playback")
        precondition(startup(playing + ["Queue->Player synchronization completed [removed all player items] - player:P/NA 0x2"]).state == .stopped)
        func report(_ item: String, rate: Int = 48_000, bits: Int = 24,
                    codec: String = "qlac", rendition: String = "Lossless") -> String {
            "fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0x123|P/NA]: <0x456|\(item)>: [AudioFormat \(codec) is decodable] [Rendition \(rendition)] [SampleRate \(rate)] [BitDepth \(bits)]"
        }
        precondition(startup([report("I/AAA.01")]).item == nil && !startup([report("I/AAA.01")]).isPlaying,
                     "An ALAC report alone must not activate a preloaded track")
        let recovered = startup([report("I/AAA.01", rate: 44_100, bits: 16),
                                 "[PL:test] Received player event: playbackDidStart: I/AAA"])
        precondition(recovered.item == "I/AAA" && recovered.isPlaying && recovered.format == low,
                     "Resume after launch can lack a current-item record and full candidates")
        let missingCandidates = startup([current("I/AAA"), report("I/AAA.01"), playing[2]])
        precondition(missingCandidates.isPlaying && missingCandidates.format == LosslessFormat(sampleRate: 48_000, bitDepth: 24))
        precondition(startup(playing + [report("I/AAA.01")]).format == high,
                     "Lower playback reports must not override a higher full candidate")
        precondition(startup([current("I/AAA"), playing[2], report("I/BBB.01")]).format == nil,
                     "A preloaded track's playback report is not the current track's format")
        precondition(startup([current("I/AAA"), playing[2], report("I/AAA.01", codec: "qaac")]).format == nil)
        precondition(startup([current("I/AAA"), playing[2], report("I/AAA.01", rendition: "DolbyAtmos")]).format == nil)
        precondition(startup([current("I/AAA"), playing[2], report("I/AAA.01", bits: 0)]).format == nil)
        precondition(startup([report("I/AAA.01"), playing[2], stop]).state == .paused)
        let reportAfterStart = startup([playing[2], report("I/AAA.01")])
        precondition(reportAfterStart.isPlaying && reportAfterStart.format == LosslessFormat(sampleRate: 48_000, bitDepth: 24))
        precondition(startup([report("I/AAA.01"), playing[2],
                              "Queue->Player synchronization completed [removed all player items] - player:P/ZZ 0x2"]).isPlaying,
                     "Recovered player identity must ignore an unrelated player's clear")
        print("PASS: fragmented lists, filtered variants, preload, maximum, pause/resume, player-scoped clear, new process, playback states, reverse startup recovery, ALAC reports and resume without current event")

        if CommandLine.arguments.count == 3 {
            try replay(log: CommandLine.arguments[1], expected: CommandLine.arguments[2])
        }
    }

    private static func replay(log: String, expected: String) throws {
        struct Expected: Decodable {
            let item: String
            let highest: [Double]
        }
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: URL(filePath: expected)))
        let data = try Data(contentsOf: URL(filePath: log))
        var tracker = MusicLogTracker()
        var observed: [String: LosslessFormat] = [:]
        var publications = 0
        var previous = MusicPlayback()
        for line in data.split(separator: 10) {
            guard let entry = try? JSONDecoder().decode(MusicLogEntry.self, from: Data(line)) else { continue }
            tracker.consume(entry)
            let state = tracker.playback
            if state.isPlaying, let item = state.item, let format = state.format {
                observed[item] = format
                if state.item != previous.item || state.format != previous.format || !previous.isPlaying {
                    publications += 1
                }
            }
            previous = state
        }
        for value in expected {
            let format = LosslessFormat(sampleRate: value.highest[0], bitDepth: UInt32(value.highest[1]))
            precondition(observed[value.item] == format, "Replay mismatch: \(value.item)")
        }
        precondition(observed.count == expected.count)
        print("PASS: real-log replay matched all \(expected.count) current items; \(publications) playing/format transitions")
    }
}
