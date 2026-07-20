import AppKit
import ApplicationServices

// Claude デスクトップアプリのサイドバーから、タイトル一致のセッション行を
// アクセシビリティAPIで直接クリックして開く。
enum ClaudeSidebar {

    // アプリ前面化の直後に呼ぶ。少し待ってからサイドバーを走査してクリックする。
    @MainActor
    static func openSession(titled title: String) {
        guard AXIsProcessTrusted() else {
            NSLog("ClaudeSidebar: アクセシビリティ権限が無いのだ（システム設定 > プライバシー > アクセシビリティ で許可）")
            requestAccessibilityIfNeeded()
            return
        }
        guard let pid = claudePID() else { return }
        let app = AXUIElementCreateApplication(pid)

        // Electron(Chromium)は、AXクライアントが下記フラグを立てて初めて
        // web部分（サイドバーのセッション行）のアクセシビリティツリーを構築する。
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        // 前面化アニメーション/再描画を待ってから走査（最大 ~1.2秒）
        attempt(app: app, title: title, tries: 6, delay: 0.2)
    }

    @MainActor
    private static func attempt(app: AXUIElement, title: String, tries: Int, delay: TimeInterval) {
        // チャット本文に同名テキストがあっても誤爆しないよう、探索はサイドバー配下に限定する
        // （見つからなければアプリ全体を対象にする＝ベストエフォート）
        let scope = sidebarRoot(in: app) ?? app
        if let el = findStaticText(in: scope, value: title, budget: 4000) {
            scrollToVisible(el)
            if pressRow(containing: el) { return }
            clickCenter(of: el)
            return
        }
        guard tries > 1 else {
            NSLog("ClaudeSidebar: 「\(title)」に一致する行が見つからなかったのだ")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            attempt(app: app, title: title, tries: tries - 1, delay: delay)
        }
    }

    private static func claudePID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == "Claude" || $0.bundleIdentifier == "com.anthropic.claudefordesktop" }?
            .processIdentifier
    }

    // MARK: - ツリー走査

    // サイドバー（description="サイドバー" の AXGroup）を探す
    private static func sidebarRoot(in app: AXUIElement) -> AXUIElement? {
        var remaining = 3000
        var stack: [AXUIElement] = [app]
        while let node = stack.popLast(), remaining > 0 {
            remaining -= 1
            if role(of: node) == kAXGroupRole,
               stringAttr(node, kAXDescriptionAttribute) == "サイドバー" {
                return node
            }
            if let children = copyChildren(node) {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    // value / title / description のいずれかが title 完全一致する AXStaticText を探す（深さ優先・ノード上限つき）
    private static func findStaticText(in root: AXUIElement, value title: String, budget: Int) -> AXUIElement? {
        var remaining = budget
        var stack: [AXUIElement] = [root]
        while let node = stack.popLast(), remaining > 0 {
            remaining -= 1
            if role(of: node) == kAXStaticTextRole, matchesTitle(node, title) {
                return node
            }
            if let children = copyChildren(node) {
                // 逆順で積んで、見た目の上→下の順に近い探索にする
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    private static func matchesTitle(_ el: AXUIElement, _ title: String) -> Bool {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = stringAttr(el, attr), s == title { return true }
        }
        return false
    }

    // MARK: - 行のクリック

    // StaticText から祖先を辿り、AXPress を持つ最初の行要素を押す
    private static func pressRow(containing el: AXUIElement, maxUp: Int = 6) -> Bool {
        var cur: AXUIElement? = el
        var up = 0
        while let node = cur, up <= maxUp {
            if actions(of: node).contains(kAXPressAction as String) {
                if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success { return true }
            }
            cur = parent(of: node)
            up += 1
        }
        return false
    }

    // AXPress が無い場合、要素の中心を合成マウスクリック
    private static func clickCenter(of el: AXUIElement) {
        guard let frame = frame(of: el) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func scrollToVisible(_ el: AXUIElement) {
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
    }

    // MARK: - AX 属性ヘルパー

    private static func role(of el: AXUIElement) -> String {
        stringAttr(el, kAXRoleAttribute) ?? ""
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func copyChildren(_ el: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func parent(of el: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &v) == .success else { return nil }
        guard let p = v, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }

    private static func actions(of el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let pos = axValue(el, kAXPositionAttribute, type: .cgPoint) as CGPoint?,
              let size = axValue(el, kAXSizeAttribute, type: .cgSize) as CGSize? else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // AXValueType（CGPoint/CGSize）を取り出す
    private static func axValue<T>(_ el: AXUIElement, _ attr: String, type: AXValueType) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axv = raw as! AXValue
        if type == .cgPoint {
            var p = CGPoint.zero
            if AXValueGetValue(axv, .cgPoint, &p) { return p as? T }
        } else if type == .cgSize {
            var s = CGSize.zero
            if AXValueGetValue(axv, .cgSize, &s) { return s as? T }
        }
        return nil
    }

    private static func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}
