import Foundation

// ノッチからの[許可][拒否]管理。
// PermissionRequest hook が接続を開いたまま待ち、ここが応答JSONを返すと Claude Code が動き出す。
@MainActor
final class ApprovalCenter: ObservableObject {
    struct Pending: Identifiable {
        let id: String // session_id
        let toolName: String
        let detail: String
        let respond: @Sendable (String?) -> Void
        let arrivedAt: Date
    }

    @Published var pending: [String: Pending] = [:]

    static let allowJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    static let denyJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"},"systemMessage":"ずんだノッチで拒否されたのだ"}}"#

    // 保留の自動解放秒数。応答なしなら空応答→ターミナル側の通常確認にフォールバック
    static let autoReleaseSeconds: Double = 120

    func add(_ payload: PermissionPayload, respond: @escaping @Sendable (String?) -> Void) {
        // 同一セッションの古い保留は解放してから差し替え
        pending[payload.sessionID]?.respond(nil)
        pending[payload.sessionID] = Pending(
            id: payload.sessionID,
            toolName: payload.toolName,
            detail: payload.detail,
            respond: respond,
            arrivedAt: Date()
        )
        scheduleAutoRelease(payload.sessionID, after: Self.autoReleaseSeconds)
    }

    func decide(_ id: String, allow: Bool) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.respond(allow ? Self.allowJSON : Self.denyJSON)
    }

    private func scheduleAutoRelease(_ id: String, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let p = self.pending[id] else { return }
            // 差し替え済みの新しい保留は解放しない
            guard Date().timeIntervalSince(p.arrivedAt) >= seconds - 1 else { return }
            self.pending.removeValue(forKey: id)
            p.respond(nil)
        }
    }

    var debugJSON: String {
        let rows = pending.values.map { "{\"session\":\"\($0.id)\",\"tool\":\"\($0.toolName)\"}" }
        return "[\(rows.joined(separator: ","))]"
    }
}
