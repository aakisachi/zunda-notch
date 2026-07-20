import SwiftUI

enum AgentKind: String, Codable {
    case claudeCode = "claude"
    case codex = "codex"

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

enum SessionStatus: String, Codable {
    case working
    case waitingApproval
    case done
    case idle

    var color: Color {
        switch self {
        case .working: return .cyan
        case .waitingApproval: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }

    var label: String {
        switch self {
        case .working: return "作業中"
        case .waitingApproval: return "承認待ち"
        case .done: return "完了"
        case .idle: return "待機"
        }
    }

    var sortPriority: Int {
        switch self {
        case .waitingApproval: return 0
        case .working: return 1
        case .done: return 2
        case .idle: return 3
        }
    }
}

struct AgentSession: Identifiable {
    let id: String
    var agent: AgentKind
    var projectName: String
    var status: SessionStatus
    var lastMessage: String
    var updatedAt: Date
    var cwd: String?
    var tty: String?
    var termProgram: String?
    // 本家流の表示用フィールド
    var title: String = ""            // セッションタイトル（最初の指示から生成）
    var lastUserPrompt: String = ""   // 「あなた：」行
    var lastReply: String = ""        // 返答プレビュー行

    // [Claude.app] [Terminal] などのホストアプリバッジ
    var hostAppLabel: String {
        if agent == .codex { return "Codex CLI" }
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm2"
        case "vscode": return "VS Code"
        case "ghostty": return "Ghostty"
        default:
            return (tty == nil || tty?.isEmpty == true) ? "Claude.app" : "CLI"
        }
    }

    // [1m] [2h] などの経過時間バッジ
    var timeAgoLabel: String {
        let sec = Int(Date().timeIntervalSince(updatedAt))
        if sec < 60 { return "\(max(sec, 1))s" }
        if sec < 3600 { return "\(sec / 60)m" }
        return "\(sec / 3600)h"
    }
}

enum EventEffect {
    case none
    case pop(voiceLine: String?)
}

// TranscriptWatcher が見つけた稼働中セッション
struct WatcherSession {
    let sessionID: String
    let cwd: String?
    let lastUser: String?
    let lastAssistant: String?
    let mtime: Date
    var title: String? // デスクトップアプリのセッション名（サイドバーの表示名）
}

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []

    // ノッチに表示する分だけ（グレー丸＝待機/確認済みは隠す）
    var visibleSessions: [AgentSession] {
        sessions.filter { $0.status != .idle }
    }

    // ノッチのバッジ用：対応が必要なセッション数（承認待ち＋完了=確認待ち）
    var attentionCount: Int {
        sessions.filter { $0.status == .waitingApproval || $0.status == .done }.count
    }

    // 起動直後の見た目確認用。最初の本物イベントで消える
    func loadDummyData() {
        sessions = [
            AgentSession(id: "zn-dummy-1", agent: .claudeCode, projectName: "（デモ表示）claude_code",
                         status: .working, lastMessage: "Claude Code を動かすと本物に置き換わるのだ",
                         updatedAt: Date()),
        ]
    }

    func apply(_ event: HookEvent) -> EventEffect {
        sessions.removeAll { $0.id.hasPrefix("zn-dummy-") }

        switch event.hookEventName {
        case "SessionStart":
            upsert(event) { s in
                s.status = .idle
                s.lastMessage = "セッション開始"
            }
            return .none

        case "UserPromptSubmit":
            upsert(event) { s in
                s.status = .working
                let prompt = Self.short(event.userPrompt ?? "作業中...", limit: 80)
                s.lastUserPrompt = prompt
                s.lastMessage = prompt
                if s.title.isEmpty {
                    s.title = Self.short(event.userPrompt ?? "", limit: 16)
                }
                s.lastReply = ""
            }
            return .none

        case "PostToolUse":
            upsert(event) { s in
                s.status = .working
                s.lastMessage = "ツール実行: \(event.toolName ?? "?")"
            }
            return .none

        case "Stop":
            upsert(event) { s in
                s.status = .done
                let reply = Self.short(event.lastAssistantMessage ?? "完了", limit: 80)
                s.lastReply = reply
                s.lastMessage = reply
            }
            return .pop(voiceLine: "できたのだ！")

        case "Notification":
            switch event.notificationType {
            case "permission_prompt":
                upsert(event) { s in
                    s.status = .waitingApproval
                    s.lastMessage = Self.short(event.message ?? "許可待ち")
                }
                return .pop(voiceLine: "許可がほしいのだ！")
            case "idle_prompt":
                upsert(event) { s in
                    if s.status == .working { s.status = .idle }
                }
                return .none
            default:
                return .none
            }

        case "SessionEnd":
            sessions.removeAll { $0.id == event.sessionID }
            return .none

        default:
            return .none
        }
    }

    // PermissionRequest hook 到着（ノッチ承認の保留開始）
    func markWaitingApproval(sessionID: String, cwd: String?, toolName: String, detail: String) {
        sessions.removeAll { $0.id.hasPrefix("zn-dummy-") }
        let synthetic = HookEvent(
            hookEventName: "Notification", sessionID: sessionID, cwd: cwd,
            notificationType: nil, message: nil, lastAssistantMessage: nil,
            userPrompt: nil, toolName: nil, source: nil, reason: nil,
            tty: nil, termProgram: nil
        )
        upsert(synthetic) { s in
            s.status = .waitingApproval
            s.lastMessage = "\(toolName): \(detail)"
        }
    }

    // ノッチで許可/拒否を押した後の表示更新
    func resolveApproval(sessionID: String, allowed: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].status = allowed ? .working : .idle
        sessions[idx].lastMessage = allowed ? "許可したのだ → 実行中" : "拒否したのだ"
        sessions[idx].updatedAt = Date()
    }

    // Codex CLI（agent-turn-complete）
    func applyCodex(threadID: String, cwd: String?, lastMessage: String?,
                    tty: String? = nil, termProgram: String? = nil) -> EventEffect {
        sessions.removeAll { $0.id.hasPrefix("zn-dummy-") }
        let name = Self.projectName(from: cwd)
        let reply = Self.short(lastMessage ?? "ターン完了", limit: 80)
        let cleanTTY = (tty == "??" || tty?.isEmpty == true) ? nil : tty
        if let idx = sessions.firstIndex(where: { $0.id == threadID }) {
            sessions[idx].status = .done
            sessions[idx].lastMessage = reply
            sessions[idx].lastReply = reply
            sessions[idx].updatedAt = Date()
            if let cleanTTY { sessions[idx].tty = cleanTTY }
            if let termProgram, !termProgram.isEmpty { sessions[idx].termProgram = termProgram }
        } else {
            var s = AgentSession(
                id: threadID, agent: .codex, projectName: name,
                status: .done, lastMessage: reply,
                updatedAt: Date(), cwd: cwd, tty: cleanTTY, termProgram: termProgram
            )
            s.title = "Codex ターン"
            s.lastReply = reply
            sessions.append(s)
        }
        resort()
        return .pop(voiceLine: "コデックス、できたのだ！")
    }

    private func resort() {
        sessions.sort {
            if $0.status.sortPriority != $1.status.sortPriority {
                return $0.status.sortPriority < $1.status.sortPriority
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    // TranscriptWatcher の結果を反映（hooks の新鮮な情報は上書きしない）
    func applyWatcher(_ found: [WatcherSession]) {
        sessions.removeAll { $0.id.hasPrefix("zn-dummy-") }
        let now = Date()

        for w in found {
            if let idx = sessions.firstIndex(where: { $0.id == w.sessionID }) {
                var s = sessions[idx]
                // セッション名（サイドバーの表示名）は常に最新を反映
                if let t = w.title, !t.isEmpty, s.title != t {
                    s.title = t
                    sessions[idx] = s
                }
                // hooks 由来の更新が25秒以内なら watcher は黙る
                if now.timeIntervalSince(s.updatedAt) < 25 { continue }
                if s.status == .waitingApproval { continue }
                if w.mtime > s.updatedAt.addingTimeInterval(5) {
                    // 記録が hook 更新より進んでいる＝新しい活動あり
                    if now.timeIntervalSince(w.mtime) < 90 { s.status = .working }
                    if let a = w.lastAssistant {
                        s.lastReply = Self.short(a, limit: 80)
                        s.lastMessage = s.lastReply
                    }
                    if let u = w.lastUser {
                        s.lastUserPrompt = Self.short(u, limit: 80)
                        if s.title.isEmpty { s.title = Self.short(u, limit: 16) }
                    }
                    s.updatedAt = w.mtime
                    sessions[idx] = s
                } else if s.status == .working, now.timeIntervalSince(w.mtime) > 150 {
                    // 記録が止まって久しいのに作業中のまま → 待機に落とす
                    s.status = .idle
                    sessions[idx] = s
                }
            } else {
                var s = AgentSession(
                    id: w.sessionID, agent: .claudeCode,
                    projectName: Self.projectName(from: w.cwd),
                    status: now.timeIntervalSince(w.mtime) < 90 ? .working : .idle,
                    lastMessage: "", updatedAt: w.mtime,
                    cwd: w.cwd, tty: nil, termProgram: nil
                )
                if let u = w.lastUser {
                    s.lastUserPrompt = Self.short(u, limit: 80)
                    s.title = Self.short(u, limit: 16)
                }
                if let t = w.title, !t.isEmpty { s.title = t }
                if let a = w.lastAssistant {
                    s.lastReply = Self.short(a, limit: 80)
                    s.lastMessage = s.lastReply
                }
                if s.lastMessage.isEmpty { s.lastMessage = s.lastUserPrompt }
                sessions.append(s)
            }
        }

        // 45分以上記録の無い Claude セッションは片付ける（Codex は hooks 管理のまま）
        let foundIDs = Set(found.map(\.sessionID))
        sessions.removeAll { s in
            s.agent == .claudeCode && !foundIDs.contains(s.id)
                && now.timeIntervalSince(s.updatedAt) > 45 * 60
        }
        resort()
    }

    var debugJSON: String {
        let rows = sessions.map { s in
            "{\"id\":\"\(s.id)\",\"project\":\"\(s.projectName)\",\"title\":\"\(s.title)\",\"status\":\"\(s.status.rawValue)\"}"
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private func upsert(_ event: HookEvent, mutate: (inout AgentSession) -> Void) {
        let name = Self.projectName(from: event.cwd)
        if let idx = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            var s = sessions[idx]
            s.updatedAt = Date()
            if let cwd = event.cwd { s.cwd = cwd; s.projectName = name }
            if let tty = event.tty, !tty.isEmpty, tty != "??" { s.tty = tty }
            if let term = event.termProgram, !term.isEmpty { s.termProgram = term }
            mutate(&s)
            sessions[idx] = s
        } else {
            var s = AgentSession(
                id: event.sessionID,
                agent: .claudeCode,
                projectName: name,
                status: .idle,
                lastMessage: "",
                updatedAt: Date(),
                cwd: event.cwd,
                tty: (event.tty == "??") ? nil : event.tty,
                termProgram: event.termProgram
            )
            mutate(&s)
            sessions.append(s)
        }
        resort()
    }

    private static func projectName(from cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "不明なプロジェクト" }
        return (cwd as NSString).lastPathComponent
    }

    private static func short(_ text: String, limit: Int = 48) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    // 折りたたみバーに出す「いちばん注目のセッション」
    var featuredSession: AgentSession? { sessions.first }
}
