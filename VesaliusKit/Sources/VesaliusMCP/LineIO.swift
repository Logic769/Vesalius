import Foundation

/// Newline-delimited messages from a file descriptor, read on a dedicated thread so a blocking read never holds
/// up the tasks answering requests. Splits on byte 0x0A only: `FileHandle.bytes.lines` also splits on U+0085,
/// U+2028 and U+2029, which may appear unescaped inside JSON strings.
enum LineReader {
    static func lines(from descriptor: Int32) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    buffer.append(contentsOf: chunk[0..<count])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if !isBlank(line) { continuation.yield(Data(line)) }
                    }
                }
                if !isBlank(buffer) { continuation.yield(buffer) }
                continuation.finish()
            }
            thread.name = "vesalius-mcp-reader"
            thread.start()
        }
    }

    static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
    }
}

/// Writes whole lines from any task, one at a time. With SIGPIPE ignored, writing to a closed pipe throws instead
/// of ending the process; after that the writer drops everything.
final class LineWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        lock.withLock {
            guard !closed else { return }
            do {
                try handle.write(contentsOf: line)
            } catch {
                closed = true
            }
        }
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }
}
