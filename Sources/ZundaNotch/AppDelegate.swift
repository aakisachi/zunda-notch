import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchController?
    private var store: SessionStore?
    private var approval: ApprovalCenter?
    private var server: EventServer?
    private var watcher: TranscriptWatcher?
    private var codexWatcher: CodexWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore()
        store.loadDummyData()
        self.store = store

        let approval = ApprovalCenter()
        self.approval = approval

        let controller = NotchController(store: store, approval: approval)
        controller.show()
        notchController = controller

        let server = EventServer { [weak self] event in
            Task { @MainActor in
                guard let self, let store = self.store else { return }
                let effect = store.apply(event)
                if case .pop(let voiceLine) = effect {
                    self.notchController?.popNotify()
                    if let voiceLine {
                        VoiceVox.notify(voiceLine, sound: "Pop")
                    }
                }
            }
        }

        // ノッチからの承認（PermissionRequest hook が応答を待っている）
        server.onPermission = { [weak self] payload, respond in
            Task { @MainActor in
                guard let self, let store = self.store, let approval = self.approval else {
                    respond(nil)
                    return
                }
                approval.add(payload, respond: respond)
                store.markWaitingApproval(
                    sessionID: payload.sessionID,
                    cwd: payload.cwd,
                    toolName: payload.toolName,
                    detail: payload.detail
                )
                self.notchController?.popNotify(forceExpand: true)
                VoiceVox.notify("許可がほしいのだ！", sound: "Ping")
            }
        }

        // Codex（ChatGPT アプリ）の notify（agent-turn-complete）。
        // セッションの検知・表示は CodexWatcher（~/.codex/sessions 監視）に一本化し、
        // ここでは即時に最新状態を反映して、ポップ＋音声だけ担当する。
        server.onCodex = { [weak self] obj in
            Task { @MainActor in
                guard let self else { return }
                guard (obj["type"] as? String) == "agent-turn-complete" else { return }
                self.codexWatcher?.tickNow()
                self.notchController?.popNotify()
                VoiceVox.notify("コデックス、できたのだ！", sound: "Pop")
            }
        }

        server.debugSnapshot = { [weak self] in
            guard Thread.isMainThread, let self else { return "{}" }
            let sessions = self.store?.debugJSON ?? "[]"
            let pending = self.approval?.debugJSON ?? "[]"
            let u = UsageMonitor.shared.stats
            let usage = u.map {
                "{\"claude5h\":\($0.claude5hTokens),\"claude7d\":\($0.claude7dTokens),\"codex5hPct\":\($0.codex5hPct.map(String.init) ?? "null"),\"codex7dPct\":\($0.codex7dPct.map(String.init) ?? "null")}"
            } ?? "null"
            return "{\"sessions\":\(sessions),\"pending\":\(pending),\"usage\":\(usage)}"
        }

        server.start()
        self.server = server

        // hooks が来ないセッションも拾う保険（transcript 直接監視）
        let watcher = TranscriptWatcher(store: store)
        watcher.start()
        self.watcher = watcher

        let codexWatcher = CodexWatcher(store: store)
        codexWatcher.start()
        self.codexWatcher = codexWatcher
    }
}
