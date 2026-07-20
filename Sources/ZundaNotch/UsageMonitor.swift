import Foundation

// 使用量ゲージのデータ源（すべてローカル・通信なし）
// - Codex : ~/.codex/sessions/**.jsonl の rate_limits（公式の used_percent）
// - Claude: ~/.claude/projects/**.jsonl のトークン実測（公式上限はこの環境で取得不可のため、
//           設定の「目安」上限に対する割合で表示する）
struct UsageStats {
    // Claude: 実測トークン（5時間窓 / 7日窓）＝目安ゲージ用
    var claude5hTokens = 0
    var claude7dTokens = 0
    // Claude: 公式%（トークン設定済みのときだけ入る）
    var claudeOfficial5hPct: Int?
    var claudeOfficial5hReset: Date?
    var claudeOfficial7dPct: Int?
    var claudeOfficial7dReset: Date?
    // Codex: 公式% （プランに存在する窓だけ値が入る）
    var codex5hPct: Int?
    var codex5hReset: Date?
    var codex7dPct: Int?
    var codex7dReset: Date?
    var codexPlan: String?
    var fetchedAt = Date()
}

@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published var stats: UsageStats?

    private var timer: Timer?
    private var isFetching = false
    private var lastFetchAt = Date.distantPast

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 90) {
        guard Date().timeIntervalSince(lastFetchAt) > maxAge else { return }
        refresh()
    }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        lastFetchAt = Date()
        Task.detached(priority: .utility) {
            let s = await Self.scan()
            await MainActor.run {
                self.stats = s
                self.isFetching = false
            }
        }
    }

    nonisolated private static func scan() async -> UsageStats {
        var s = UsageStats()
        let claude = scanClaudeWindows()
        s.claude5hTokens = claude.fiveHour
        s.claude7dTokens = claude.sevenDay
        if let rate = scanCodexRateLimits() {
            s.codex5hPct = rate.fiveHourPct
            s.codex5hReset = rate.fiveHourReset
            s.codex7dPct = rate.sevenDayPct
            s.codex7dReset = rate.sevenDayReset
            s.codexPlan = rate.plan
        }
        // トークンが設定されていれば Claude 公式%も取得
        if let token = ClaudeToken.load(), let official = await fetchClaudeOfficial(token: token) {
            s.claudeOfficial5hPct = official.fiveHourPct
            s.claudeOfficial5hReset = official.fiveHourReset
            s.claudeOfficial7dPct = official.sevenDayPct
            s.claudeOfficial7dReset = official.sevenDayReset
        }
        return s
    }

    // Anthropic 公式の使用量API（要OAuthトークン。通信先はapi.anthropic.comのみ）
    struct ClaudeOfficial {
        var fiveHourPct: Int?
        var fiveHourReset: Date?
        var sevenDayPct: Int?
        var sevenDayReset: Date?
    }

    nonisolated private static func fetchClaudeOfficial(token: String) async -> ClaudeOfficial? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else {
            NSLog("UsageMonitor: official usage HTTP %d", http.statusCode)
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func window(_ key: String) -> (Int, Date?)? {
            guard let w = obj[key] as? [String: Any],
                  let raw = w["utilization"] as? Double else { return nil }
            var reset: Date?
            if let sStr = w["resets_at"] as? String { reset = parseISO(sStr) }
            return (Int(raw.rounded()), reset)
        }
        var o = ClaudeOfficial()
        if let five = window("five_hour") { o.fiveHourPct = five.0; o.fiveHourReset = five.1 }
        if let seven = window("seven_day") { o.sevenDayPct = seven.0; o.sevenDayReset = seven.1 }
        return (o.fiveHourPct != nil || o.sevenDayPct != nil) ? o : nil
    }

    nonisolated private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Claude（5時間窓・7日窓のトークン実測）

    nonisolated private static func scanClaudeWindows() -> (fiveHour: Int, sevenDay: Int) {
        let root = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return (0, 0) }

        let now = Date()
        let cutoff5h = now.addingTimeInterval(-5 * 3600)
        let cutoff7d = now.addingTimeInterval(-7 * 86400)
        // ISO8601文字列は辞書順比較で時刻比較できる（高速化：JSONパース前に足切り）
        let isoWriter = ISO8601DateFormatter()
        isoWriter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff5hStr = isoWriter.string(from: cutoff5h)
        let cutoff7dStr = isoWriter.string(from: cutoff7d)

        var fiveHour = 0
        var sevenDay = 0

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let path = root + "/" + rel
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff7d else { continue }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            content.enumerateLines { line, _ in
                guard line.contains("\"output_tokens\"") else { return }
                // タイムスタンプの文字列足切り
                var tsStr: String?
                if let r = line.range(of: "\"timestamp\":\"") {
                    let rest = line[r.upperBound...]
                    if let end = rest.firstIndex(of: "\"") { tsStr = String(rest[..<end]) }
                }
                if let tsStr, tsStr < cutoff7dStr { return }

                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = findDict(obj, containingKey: "output_tokens") else { return }
                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                guard tokens > 0 else { return }

                sevenDay += tokens
                if let tsStr {
                    if tsStr >= cutoff5hStr { fiveHour += tokens }
                } else if mtime >= cutoff5h {
                    fiveHour += tokens
                }
            }
        }
        return (fiveHour, sevenDay)
    }

    // MARK: - Codex（公式レート制限スナップショット）

    struct CodexRate {
        var fiveHourPct: Int?
        var fiveHourReset: Date?
        var sevenDayPct: Int?
        var sevenDayReset: Date?
        var plan: String?
    }

    nonisolated private static func scanCodexRateLimits() -> CodexRate? {
        let base = NSHomeDirectory() + "/.codex/sessions"
        let fm = FileManager.default
        let cal = Calendar.current

        // 新しい日から順に、rate_limits を含む最新ファイルを探す
        for dayOffset in 0..<4 {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let folder = String(format: "%@/%04d/%02d/%02d", base,
                                cal.component(.year, from: date),
                                cal.component(.month, from: date),
                                cal.component(.day, from: date))
            guard let files = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            // ファイル名に時刻が入っているので降順=新しい順
            for file in files.filter({ $0.hasSuffix(".jsonl") }).sorted(by: >) {
                if let rate = lastRateLimits(folder + "/" + file) { return rate }
            }
        }
        return nil
    }

    nonisolated private static func lastRateLimits(_ path: String) -> CodexRate? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var lastDict: [String: Any]?
        content.enumerateLines { line, _ in
            guard line.contains("\"rate_limits\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = findDict(obj, containingKey: "rate_limits")?["rate_limits"] as? [String: Any]
            else { return }
            lastDict = rl
        }
        guard let rl = lastDict else { return nil }

        var rate = CodexRate()
        rate.plan = rl["plan_type"] as? String
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any],
                  let used = w["used_percent"] as? Double,
                  let minutes = w["window_minutes"] as? Int else { continue }
            var reset: Date?
            if let epoch = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: epoch) }
            if minutes <= 1000 { // ≒5時間窓
                rate.fiveHourPct = Int(used.rounded())
                rate.fiveHourReset = reset
            } else {             // ≒7日窓
                rate.sevenDayPct = Int(used.rounded())
                rate.sevenDayReset = reset
            }
        }
        return (rate.fiveHourPct != nil || rate.sevenDayPct != nil) ? rate : nil
    }

    // 指定キーを持つ辞書を再帰的に探す
    nonisolated private static func findDict(_ obj: Any, containingKey key: String) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if dict[key] != nil { return dict }
            for value in dict.values {
                if let found = findDict(value, containingKey: key) { return found }
            }
        } else if let arr = obj as? [Any] {
            for value in arr {
                if let found = findDict(value, containingKey: key) { return found }
            }
        }
        return nil
    }
}

// トークン数を 1.2M / 340K の形に
enum TokenFormat {
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return "\(n / 1000)K"
        }
        return "\(n)"
    }
}

// 「残5d19h」表示用
enum UsageFormat {
    static func remain(_ date: Date?) -> String {
        guard let date else { return "" }
        let sec = Int(date.timeIntervalSinceNow)
        guard sec > 0 else { return "" }
        let d = sec / 86400
        let h = (sec % 86400) / 3600
        let m = (sec % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}
