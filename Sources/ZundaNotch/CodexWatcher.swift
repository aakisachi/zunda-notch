import Foundation

// Codex（ChatGPT デスクトップアプリ内）のセッションを ~/.codex/sessions のロールアウト記録から
// 直接監視する。notify（ターン完了）を待たずに、実行中のセッションもリアルタイムで拾う。
// FSEvents で書き込みを即検知し、保険として定期スキャンも回す。
struct CodexWatcherSession {
    let sessionID: String
    let cwd: String?
    let lastUser: String?
    let lastAssistant: String?
    let mtime: Date
    let working: Bool   // 直近が task_started で終わっている＝ターン実行中
}

@MainActor
final class CodexWatcher {
    private let store: SessionStore
    private var timer: Timer?
    private var fsWatcher: DirectoryWatcher?
    private var scanning = false

    private static let root = NSHomeDirectory() + "/.codex/sessions"

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        tick()
        fsWatcher = DirectoryWatcher(paths: [Self.root]) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        fsWatcher?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // notify（ターン完了）を受けたら即スキャンして done を反映するために呼ぶ
    func tickNow() { tick() }

    private func tick() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                self.scanning = false
                self.store.applyCodexWatcher(found)
            }
        }
    }

    nonisolated private static func scan() -> [CodexWatcherSession] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        let cutoff = Date().addingTimeInterval(-45 * 60)
        let now = Date()
        var out: [CodexWatcherSession] = []

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("rollout-") else { continue }
            let path = root + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else { continue }

            // 先頭（session_meta）から cwd と session_id を抽出。
            // session_meta 行には base_instructions（システムプロンプト全文）が入って巨大に
            // なるため JSON 全体パースはできない。cwd / session_id は行頭近くにあるので
            // 先頭チャンクから狙い撃ちで取り出す。
            let head = headChunk(path, maxBytes: 65536)
            let cwd = Self.jsonString(field: "cwd", in: head)
            let sessionID = Self.jsonString(field: "session_id", in: head)
            // フォールバック：ファイル名末尾の UUID
            let sid = sessionID ?? name
                .replacingOccurrences(of: ".jsonl", with: "")
                .components(separatedBy: "-").suffix(5).joined(separator: "-")

            // 末尾から状態と直近メッセージ
            let tailStr = tail(path, maxBytes: 24576)
            var working = false
            var lastUser: String?
            var lastAssistant: String?
            for lineSub in tailStr.split(separator: "\n") {
                guard let data = String(lineSub).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "event_msg",
                      let p = obj["payload"] as? [String: Any],
                      let t = p["type"] as? String else { continue }
                switch t {
                case "task_started": working = true
                case "task_complete": working = false
                case "user_message": lastUser = (p["message"] as? String) ?? lastUser
                case "agent_message": lastAssistant = (p["message"] as? String) ?? lastAssistant
                default: break
                }
            }
            // mtime が古ければ実行中扱いにしない（記録が止まっているだけ）
            if now.timeIntervalSince(mtime) > 120 { working = false }

            out.append(CodexWatcherSession(
                sessionID: sid, cwd: cwd,
                lastUser: lastUser, lastAssistant: lastAssistant,
                mtime: mtime, working: working
            ))
        }
        return out
    }

    // ファイル先頭チャンク（session_meta の頭。cwd/session_id はここに含まれる）
    nonisolated private static func headChunk(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // `"field": "value"` の value を素朴に取り出す（値にエスケープ無しのパス/UUID想定）
    nonisolated private static func jsonString(field: String, in text: String) -> String? {
        guard let r = text.range(of: "\"\(field)\"") else { return nil }
        var i = r.upperBound
        // コロンと空白と開きダブルクオートまで進む
        guard let colon = text[i...].firstIndex(of: ":") else { return nil }
        i = text.index(after: colon)
        guard let openQuote = text[i...].firstIndex(of: "\"") else { return nil }
        let valueStart = text.index(after: openQuote)
        guard let closeQuote = text[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(text[valueStart..<closeQuote])
        return value.isEmpty ? nil : value
    }

    // ファイル末尾だけ読む（巨大記録対策）
    nonisolated private static func tail(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return "" }
        var s = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        return s
    }
}
