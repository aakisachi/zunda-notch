import AppKit

// セッション行クリック → そのターミナル/アプリへジャンプ
enum FocusJumper {
    @MainActor
    static func jump(to session: AgentSession) {
        if let tty = session.tty, !tty.isEmpty {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            switch session.termProgram {
            case "Apple_Terminal":
                if runAppleScript(terminalScript(dev)) { return }
            case "iTerm.app":
                if runAppleScript(itermScript(dev)) { return }
            default:
                break
            }
        }
        // Claude デスクトップのセッション。
        // 注意: claude://resume?session=<CLIセッションID> は「インポート」であり、
        // 既存のサイドバー項目とは別に無題の複製セッション（local_<CLI-ID>）を作ってしまう。
        // 既存セッションを直接開ける claude://code/<bridgeSessionId> は
        // フィーチャーフラグ(gate 2143883161)でOFFのため現状使えない（2026-07-20 実測）。
        // → 代わりにアプリを前面化し、サイドバーの同名セッション行を
        //    アクセシビリティAPIでクリックしてピンポイントで開く（門番不要・インポートしない）。
        activateHostApp(session)
        if !session.title.isEmpty {
            ClaudeSidebar.openSession(titled: session.title)
        }
    }

    // tty 一致でタブ精度ジャンプ（Terminal.app）
    private static func terminalScript(_ dev: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(dev)" then
                        set selected of t to true
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    // tty 一致でタブ精度ジャンプ（iTerm2）
    private static func itermScript(_ dev: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(dev)" then
                            select s
                            select t
                            select w
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            NSLog("FocusJumper: AppleScript error: \(error)")
            return false
        }
        return true
    }

    // アプリ単位のフォールバック（権限不要）
    private static func activateHostApp(_ session: AgentSession) {
        let running = NSWorkspace.shared.runningApplications

        func activate(bundleID: String? = nil, name: String? = nil) -> Bool {
            for app in running {
                if let bundleID, app.bundleIdentifier == bundleID {
                    return app.activate()
                }
                if let name, app.localizedName == name {
                    return app.activate()
                }
            }
            return false
        }

        switch session.termProgram {
        case "vscode":
            if activate(bundleID: "com.microsoft.VSCode") { return }
            if activate(name: "Cursor") { return }
        case "Apple_Terminal":
            if activate(bundleID: "com.apple.Terminal") { return }
        case "iTerm.app":
            if activate(bundleID: "com.googlecode.iterm2") { return }
        case "ghostty":
            if activate(name: "Ghostty") { return }
        default:
            break
        }
        // Codex や行き先不明のCLIセッション → 起動中のターミナルを順に探す
        if session.agent == .codex || session.tty != nil {
            if activate(bundleID: "com.apple.Terminal") { return }
            if activate(bundleID: "com.googlecode.iterm2") { return }
            if activate(name: "Ghostty") { return }
            if activate(name: "Warp") { return }
        }
        // Claude Code デスクトップアプリ（tty無しセッション）
        if activate(name: "Claude") { return }
        _ = activate(bundleID: "com.apple.Terminal")
    }
}
