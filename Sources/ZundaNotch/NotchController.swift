import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchUIState: ObservableObject {
    @Published var isExpanded = false
    @Published var glowTick = 0 // 控えめ通知（光る）用
    @Published var showAllSessions = false // 「ほか N セッション」展開
}

@MainActor
final class NotchController {
    private let store: SessionStore
    private let approval: ApprovalCenter
    private let ui = NotchUIState()
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private var collapseTask: Task<Void, Never>?
    private var isHovering = false
    private var screenObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    private let settings = SettingsWindowController()

    // 見た目パラメータ
    private let collapsedExtraWidth: CGFloat = 130
    private let collapsedExtraHeight: CGFloat = 0 // 折りたたみ時はメニューバー内に収める
    private let expandedSize = NSSize(width: 540, height: 268)

    init(store: SessionStore, approval: ApprovalCenter) {
        self.store = store
        self.approval = approval
        self.geometry = NotchGeometry.bestScreen()
        self.panel = NotchPanel(contentRect: .zero)
    }

    func show() {
        let root = NotchView(
            store: store,
            approval: approval,
            ui: ui,
            notchWidth: geometry.notchRect.width,
            notchHeight: geometry.notchRect.height,
            onHoverChanged: { [weak self] hovering in
                self?.handleHover(hovering)
            },
            onDecide: { [weak self] sessionID, allow in
                self?.decide(sessionID: sessionID, allow: allow)
            },
            onOpenSettings: { [weak self] in
                self?.openSettingsAndCollapse()
            }
        )
        panel.contentView = ClickableHostingView(rootView: root)
        applyFrame(expanded: false)
        panel.orderFrontRegardless()
        UsageMonitor.shared.start()

        // 「ほか N セッション」の開閉に合わせてパネルの高さを変える
        ui.$showAllSessions
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.ui.isExpanded else { return }
                    self.applyFrame(expanded: true)
                }
            }
            .store(in: &cancellables)

        // ディスプレイ構成変更（外部モニタ接続など）で位置を取り直す
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.geometry = NotchGeometry.bestScreen()
                self.applyFrame(expanded: self.ui.isExpanded)
            }
        }
    }

    // イベント発生時の反応。
    // 自動展開ON か 強制（承認）→ パネルが開く / OFF → ノッチが控えめに光る
    func popNotify(forceExpand: Bool = false) {
        let autoExpand = UserDefaults.standard.bool(forKey: "autoExpandOnEvent")
        if forceExpand || autoExpand {
            collapseTask?.cancel()
            expand()
            scheduleCollapse(after: 2.5)
        } else {
            ui.glowTick += 1
        }
    }

    // 設定を開くときはノッチを即たたむ
    private func openSettingsAndCollapse() {
        isHovering = false
        collapseTask?.cancel()
        collapse()
        settings.open()
    }

    private func decide(sessionID: String, allow: Bool) {
        approval.decide(sessionID, allow: allow)
        store.resolveApproval(sessionID: sessionID, allowed: allow)
        VoiceVox.notify(allow ? "許可したのだ" : "拒否したのだ", sound: "Tink")
        scheduleCollapse(after: 1.2)
    }

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        collapseTask?.cancel()
        if hovering {
            expand()
        } else {
            // マウスが枠から出たら即たたむ（誤検知のちらつき防止に0.1秒だけ待つ）
            scheduleCollapse(after: 0.1)
        }
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard !self.isHovering else { return }
            // 承認待ちが残っている間は閉じない（2秒ごとに再確認）
            if !self.approval.pending.isEmpty {
                self.scheduleCollapse(after: 2.0)
                return
            }
            self.collapse()
        }
    }

    private func expand() {
        guard !ui.isExpanded else { return }
        applyFrame(expanded: true)
        withAnimation(.spring(duration: 0.28)) {
            ui.isExpanded = true
        }
        UsageMonitor.shared.refreshIfStale()
    }

    private func collapse() {
        guard ui.isExpanded else { return }
        ui.showAllSessions = false
        withAnimation(.spring(duration: 0.24)) {
            ui.isExpanded = false
        }
        // 縮小アニメーションが見えてからウィンドウ自体を小さくする
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !self.ui.isExpanded else { return }
            self.applyFrame(expanded: false)
        }
    }

    private func applyFrame(expanded: Bool) {
        let notch = geometry.notchRect
        var size: NSSize
        if expanded {
            size = expandedSize
            if ui.showAllSessions {
                let extraRows = max(0, min(store.sessions.count, 8) - 3)
                size.height += CGFloat(extraRows) * 52
            }
        } else {
            size = NSSize(width: notch.width + collapsedExtraWidth,
                          height: notch.height + collapsedExtraHeight)
        }
        let frame = NSRect(
            x: notch.midX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: false)
    }
}
