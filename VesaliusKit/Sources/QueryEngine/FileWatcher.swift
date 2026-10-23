import CoreServices
import Foundation
import RepositoryScanner

/// Watches a repository with FSEvents and reports batches of changed paths after a quiet period.
/// Changes inside ignored build/VCS folders are filtered out so builds do not trigger re-indexing.
public final class FileWatcher: @unchecked Sendable {
    public let root: URL
    private let latency: TimeInterval
    private let debounce: TimeInterval
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.vesalius.watcher")
    private var pending = Set<String>()
    private var timer: DispatchSourceTimer?

    public init(root: URL, latency: TimeInterval = 0.4, debounce: TimeInterval = 1.2, handler: @escaping @Sendable ([String]) -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.latency = latency
        self.debounce = debounce
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var changed: [String] = []
            for index in 0..<count {
                if let path = array[index] as? String { changed.append(path) }
            }
            watcher.receive(changed)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        timer?.cancel()
        timer = nil
    }

    private func receive(_ paths: [String]) {
        let rootPath = root.path + "/"
        let excluded = ScanOptions.defaultExcludedDirectories
        for path in paths {
            guard path.hasPrefix(rootPath) else {
                if path == root.path { pending.insert("") }
                continue
            }
            let relative = String(path.dropFirst(rootPath.count))
            let components = relative.split(separator: "/")
            if components.contains(where: { excluded.contains(String($0)) || ($0.hasPrefix(".") && $0 != ".gitignore" && $0 != ".vesaliusignore") }) { continue }
            if relative.hasSuffix("~") || relative.hasSuffix(".swp") || relative.hasSuffix(".tmp") { continue }
            pending.insert(relative)
        }
        guard !pending.isEmpty else { return }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounce)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending).sorted()
            self.pending.removeAll()
            self.handler(batch)
        }
        self.timer = timer
        timer.resume()
    }
}
