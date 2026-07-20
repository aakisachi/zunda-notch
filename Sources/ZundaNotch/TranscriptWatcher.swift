import Foundation

// hooks の取りこぼし対策：~/.claude/projects の作業記録(transcript)を直接監視して
// 「本当に動いている」セッションを全部拾う保険機構。12秒ごとの軽量スキャン。
@MainActor
final class TranscriptWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private var fsWatcher: DirectoryWatcher?
    private var scanning = false

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        tick()
        // 即時反応：transcript の書き込みを FSEvents で検知したら即スキャン（本家並みの速さ）
        let watchPaths = [
            NSHomeDirectory() + "/.claude/projects",
            NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions",
        ]
        fsWatcher = DirectoryWatcher(paths: watchPaths) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        fsWatcher?.start()
        // 保険：FSEvents が取りこぼしても定期スキャンで拾う（間隔は長めでよい）
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                self.scanning = false
                self.store.applyWatcher(found)
            }
        }
    }

    nonisolated private static func scan() -> [WatcherSession] {
        let root = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        let cutoff = Date().addingTimeInterval(-45 * 60)
        let titles = loadTitles()
        var out: [WatcherSession] = []

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let name = (rel as NSString).lastPathComponent
            // サブエージェントの記録・ジャーナルは対象外（本体セッションだけ表示）
            if name.hasPrefix("agent-") || name == "journal.jsonl" { continue }
            let path = root + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else { continue }

            let tailStr = tail(path, maxBytes: 24576)
            if tailStr.isEmpty { continue }
            if tailStr.contains("\"isSidechain\":true") { continue }

            var cwd: String?
            var lastUser: String?
            var lastAssistant: String?
            for lineSub in tailStr.split(separator: "\n") {
                guard let data = String(lineSub).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                guard let type = obj["type"] as? String else { continue }
                if type == "assistant", let t = messageText(obj) { lastAssistant = t }
                if type == "user", let t = messageText(obj) { lastUser = t }
            }
            guard cwd != nil || lastUser != nil || lastAssistant != nil else { continue }

            let sid = name.replacingOccurrences(of: ".jsonl", with: "")
            out.append(WatcherSession(
                sessionID: sid,
                cwd: cwd,
                lastUser: lastUser,
                lastAssistant: lastAssistant,
                mtime: mtime,
                title: titles[sid]
            ))
        }
        return out
    }

    // デスクトップアプリが保存しているセッション名（サイドバーの表示名）を
    // cliSessionId → title の対応表として読み込む
    nonisolated private static func loadTitles() -> [String: String] {
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [:] }
        var map: [String: String] = [:]
        for case let rel as String in en where rel.hasSuffix(".json") {
            let path = root + "/" + rel
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = obj["cliSessionId"] as? String,
                  let title = obj["title"] as? String, !title.isEmpty else { continue }
            map[cli] = title
        }
        return map
    }

    // ファイル末尾だけ読む（巨大transcript対策）
    nonisolated private static func tail(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return "" }
        var s = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...]) // 途中で切れた行を捨てる
        }
        return s
    }

    nonisolated private static func messageText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return cleaned(s) }
        guard let blocks = msg["content"] as? [[String: Any]] else { return nil }
        for b in blocks {
            let t = b["type"] as? String
            if t == "tool_result" || t == "tool_use" { return nil } // ツールのやり取りは表示しない
            if t == "text", let s = b["text"] as? String { return cleaned(s) }
        }
        return nil
    }

    nonisolated private static func cleaned(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") { return nil } // system-reminder等を除外
        return t
    }
}
