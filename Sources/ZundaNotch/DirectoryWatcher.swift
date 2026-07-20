import Foundation
import CoreServices

// 指定ディレクトリ配下の変更を FSEvents で即時検知する。
// transcript ファイルが書かれた瞬間に通知が来るので、ポーリング(12秒)より遥かに反応が速い。
// 連続書き込みで何度も発火するため、短いデバウンスでまとめてから onChange を呼ぶ。
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "zn.fswatch")
    private var pending: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().debouncedFire()
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // レイテンシ（秒）
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func debouncedFire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
