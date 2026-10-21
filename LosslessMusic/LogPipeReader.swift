import Darwin
import Foundation

/// A quiet stderr pipe must never block stdout (or another process's output).
/// All buffer access is confined to this reader's private dispatch queue.
final class LogPipeReader: @unchecked Sendable {
    private let source: any DispatchSourceRead
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let onEnd: @Sendable (String?) -> Void
    private var pending = Data()

    init(handle: FileHandle, onLine: @escaping @Sendable (String) -> Void,
         onEnd: @escaping @Sendable (String?) -> Void) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.handle = handle
        self.onLine = onLine
        self.onEnd = onEnd
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                              queue: DispatchQueue(label: "LosslessMusic.pipe.\(descriptor)"))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    func stop() { source.cancel() }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    onLine(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            } else if count == 0 {
                if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll()
                source.cancel()
                onEnd(nil)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                let error = String(cString: strerror(errno))
                source.cancel()
                onEnd(error)
                return
            }
        }
    }
}
