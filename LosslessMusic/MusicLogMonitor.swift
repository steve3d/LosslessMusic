import Foundation

@MainActor
final class MusicLogMonitor {
    var onEntry: ((MusicLogEntry, Bool) -> Void)?
    var onReady: (([MusicLogEntry]) -> Void)?
    var onError: ((String) -> Void)?

    private final class Session {
        let process = Process()
        let historical: Bool
        var readers: [LogPipeReader] = []
        var stdoutEnded = false
        var stderrEnded = false
        var status: Int32?
        var lines = 0
        var decoded = 0
        var failures = 0
        var stderr: [String] = []

        init(historical: Bool) { self.historical = historical }
    }

    private var sessions: [UUID: Session] = [:]
    private var buffered: [MusicLogEntry] = []
    private var catchingUp = true
    private var historicalEntries: [MusicLogEntry] = []
    private var generation = 0

    private static let predicate = """
        process == "Music" AND (
        eventMessage CONTAINS "fasb_log:" OR
        (eventMessage CONTAINS "fpfs_ReportAudioPlaybackThroughFigLog:" AND
         eventMessage CONTAINS "[Rendition Lossless]" AND
         (eventMessage CONTAINS "[AudioFormat qlac " OR eventMessage CONTAINS "[AudioFormat alac ")) OR
        eventMessage CONTAINS "AVPlayer [itemDidBecomeCurrent]" OR
        eventMessage CONTAINS "Received player event: playbackDidStart:" OR
        eventMessage CONTAINS "Received player event: playbackDidStop:" OR
        eventMessage CONTAINS "Received player event: currentItemWillChange:" OR
        eventMessage CONTAINS "removed all player items" OR
        eventMessage CONTAINS "PlayerController state did change:")
        """


    func start(processID: Int32) {
        stop()
        catchingUp = true
        let token = generation
        MusicDiagnostics.log("MONITOR_START", "Music pid=\(processID); start live stream and 15m history catch-up")
        let predicate = Self.predicate + " AND processID == \(processID)"
        launch(["stream", "--style", "ndjson", "--level", "debug", "--predicate", predicate],
               historical: false, token: token)
        launch(["show", "--last", "15m", "--style", "ndjson", "--info", "--debug", "--no-pager",
                "--predicate", predicate], historical: true, token: token)
    }

    func stop() {
        if !sessions.isEmpty { MusicDiagnostics.log("MONITOR_STOP", "Stop log processes and pipe readers") }
        generation += 1
        for session in sessions.values {
            session.process.terminationHandler = nil
            if session.process.isRunning { session.process.terminate() }
            for reader in session.readers { reader.stop() }
        }
        sessions.removeAll()
        buffered.removeAll()
        historicalEntries.removeAll()
    }

    private func launch(_ arguments: [String], historical: Bool, token: Int) {
        guard token == generation else { return }
        let id = UUID()
        let session = Session(historical: historical)
        let output = Pipe()
        let errors = Pipe()
        let process = session.process
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        sessions[id] = session
        do {
            for (pipe, isError) in [(output, false), (errors, true)] {
                let reader = try LogPipeReader(handle: pipe.fileHandleForReading, onLine: { [weak self] line in
                    DispatchQueue.main.async { [weak self] in
                        self?.receive(line, id: id, isError: isError, token: token)
                    }
                }, onEnd: { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token, let session = self.sessions[id] else { return }
                        if let error {
                            MusicDiagnostics.log("PIPE_READ_FAILED", error)
                            self.onError?(String(localized: "Read failed"))
                            return
                        }
                        if isError { session.stderrEnded = true } else { session.stdoutEnded = true }
                        self.finishIfReady(id: id)
                    }
                })
                session.readers.append(reader)
            }
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, let session = self.sessions[id] else { return }
                    session.status = status
                    self.finishIfReady(id: id)
                }
            }
            try process.run()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            MusicDiagnostics.log(historical ? "HISTORY_BEGIN" : "STREAM_BEGIN", "log subprocess pid=\(process.processIdentifier)")
        } catch {
            for reader in session.readers { reader.stop() }
            sessions.removeValue(forKey: id)
            MusicDiagnostics.log("MONITOR_START_FAILED", error.localizedDescription)
            onError?(String(localized: "Start failed"))
        }
    }

    private func receive(_ line: String, id: UUID, isError: Bool, token: Int) {
        guard generation == token, let session = sessions[id] else { return }
        let channel = session.historical ? "HISTORY" : "STREAM"
        if isError {
            if !line.isEmpty {
                if session.stderr.count < 8 { session.stderr.append(line) }
                MusicDiagnostics.log("\(channel)_STDERR", line)
            }
            return
        }
        session.lines += 1
        if session.lines == 1 { MusicDiagnostics.log("\(channel)_FIRST_LINE", String(line.prefix(400))) }
        guard line.first == "{" else {
            if !line.isEmpty { MusicDiagnostics.log("\(channel)_TEXT", String(line.prefix(400))) }
            return
        }
        do {
            let data = Data(line.utf8)
            // log show emits a final summary object, not a playback event.
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["finished"] != nil { return }
            let entry = try JSONDecoder().decode(MusicLogEntry.self, from: data)
            session.decoded += 1
            if session.decoded == 1 || session.decoded.isMultiple(of: 500) {
                MusicDiagnostics.log("\(channel)_PROGRESS", "lines=\(session.lines) decoded=\(session.decoded) failures=\(session.failures)")
            }
            if session.historical { historicalEntries.append(entry) }
            else if catchingUp { buffered.append(entry) }
            else { onEntry?(entry, false) }
        } catch {
            session.failures += 1
            if session.failures <= 3 {
                MusicDiagnostics.log("\(channel)_DECODE_FAILED", "\(error) | \(line.prefix(500))")
            }
        }
    }

    private func finishIfReady(id: UUID) {
        guard let session = sessions[id], session.stdoutEnded, session.stderrEnded,
              let status = session.status else { return }
        sessions.removeValue(forKey: id)
        for reader in session.readers { reader.stop() }
        let channel = session.historical ? "HISTORY" : "STREAM"
        MusicDiagnostics.log("\(channel)_EXIT", "status=\(status) lines=\(session.lines) decoded=\(session.decoded) failures=\(session.failures)")
        guard status == 0 else {
            MusicDiagnostics.log("\(channel)_FAILED", "status=\(status); \(session.stderr.joined(separator: " "))")
            onError?(String(localized: "Log stopped"))
            return
        }
        guard session.failures == 0 else {
            onError?(String(localized: "Decode failed"))
            return
        }
        guard session.historical else { onError?(String(localized: "Log stopped")); return }
        let merged = (historicalEntries + buffered).enumerated().sorted {
            if $0.element.timestamp != $1.element.timestamp { return $0.element.timestamp < $1.element.timestamp }
            if $0.element.machTimestamp != $1.element.machTimestamp { return $0.element.machTimestamp < $1.element.machTimestamp }
            return $0.offset < $1.offset
        }
        var seen = Set<LogIdentity>()
        var entries: [MusicLogEntry] = []
        for (_, entry) in merged {
            if seen.insert(LogIdentity(entry)).inserted {
                entries.append(entry)
                onEntry?(entry, true)
            }
        }
        MusicDiagnostics.log("HISTORY_END", "history=\(historicalEntries.count) bufferedLive=\(buffered.count) unique=\(seen.count)")
        buffered.removeAll()
        historicalEntries.removeAll()
        catchingUp = false
        onReady?(entries)
    }
}

private struct LogIdentity: Hashable {
    let process: Int32
    let timestamp: String
    let time: UInt64
    let message: String

    init(_ entry: MusicLogEntry) {
        process = entry.processID
        timestamp = entry.timestamp
        time = entry.machTimestamp
        message = entry.eventMessage
    }
}
