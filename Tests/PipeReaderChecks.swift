import Foundation

@MainActor
private final class Capture {
    var output: [String] = []
    var errors: [String] = []
    var outputEnded = false
    var errorsEnded = false
    var failure: String?
}

@main
struct PipeReaderChecks {
    @MainActor
    static func main() async throws {
        let capture = Capture()
        let output = Pipe()
        let errors = Pipe()
        let outReader = try LogPipeReader(handle: output.fileHandleForReading, onLine: { line in
            DispatchQueue.main.async { capture.output.append(line) }
        }, onEnd: { error in
            DispatchQueue.main.async { capture.outputEnded = true; capture.failure = error ?? capture.failure }
        })
        let errReader = try LogPipeReader(handle: errors.fileHandleForReading, onLine: { line in
            DispatchQueue.main.async { capture.errors.append(line) }
        }, onEnd: { error in
            DispatchQueue.main.async { capture.errorsEnded = true; capture.failure = error ?? capture.failure }
        })
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", #"""
            printf 'first\n'
            sleep 1
            printf '\344\270'
            sleep 0.1
            printf '\255\n'
            i=0
            while [ "$i" -lt 3000 ]; do
                printf 'line-%s-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i"
                i=$((i+1))
            done
            printf 'tail-without-newline'
            printf 'diagnostic\n' >&2
            """#]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            outReader.stop()
            errReader.stop()
        }
        // stderr is open and silent for a full second. stdout must arrive anyway.
        for _ in 0..<25 {
            if capture.output.first == "first" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(capture.output.first == "first", "Quiet stderr blocked stdout")
        precondition(capture.errors.isEmpty)
        for _ in 0..<250 {
            if capture.outputEnded && capture.errorsEnded && !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(capture.failure == nil, capture.failure ?? "")
        precondition(capture.outputEnded && capture.errorsEnded, "Missing EOF")
        precondition(!process.isRunning && process.terminationStatus == 0)
        precondition(capture.output.count == 3003)
        precondition(capture.output[1] == "中", "UTF-8 split across reads was corrupted")
        precondition(capture.output.last == "tail-without-newline")
        precondition(capture.errors == ["diagnostic"])
        print("PASS: live stdout while stderr stays silent; 3000 ordered lines beyond pipe capacity; split UTF-8; EOF tail; stderr delivery")
    }
}
