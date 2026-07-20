import SwiftUI

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var approval: ApprovalCenter
    @ObservedObject var ui: NotchUIState
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDecide: (String, Bool) -> Void
    let onOpenSettings: () -> Void

    @AppStorage("zundaVoiceEnabled") private var zundaVoice = true
    @AppStorage("notchApprovalEnabled") private var notchApproval = true
    @AppStorage("claudeBudget5hM") private var claudeBudget5hM = 15
    @AppStorage("claudeBudget7dM") private var claudeBudget7dM = 500
    @AppStorage("showUsageStrip") private var showUsageStrip = false
    @State private var glowOpacity: Double = 0
    @ObservedObject private var usage = UsageMonitor.shared

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: ui.isExpanded ? 18 : 13,
                bottomTrailingRadius: ui.isExpanded ? 18 : 13,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(.black)

            if ui.isExpanded {
                expandedContent
            } else {
                collapsedContent
            }

            // 控えめ通知：下辺がふわっと光る
            VStack {
                Spacer()
                Capsule()
                    .fill(featuredColor)
                    .frame(height: 2)
                    .padding(.horizontal, 18)
                    .opacity(glowOpacity)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: onHoverChanged)
        .onChange(of: ui.glowTick) { _, _ in
            glowOpacity = 0.95
            withAnimation(.easeOut(duration: 1.8)) {
                glowOpacity = 0
            }
        }
    }

    private var featured: AgentSession? { store.featuredSession }
    private var featuredColor: Color { featured?.status.color ?? .green }

    // MARK: - 折りたたみ：バディ｜（カメラ）｜件数（メニューバーからはみ出さない高さ）

    private var collapsedContent: some View {
        HStack {
            PixelBuddy(tint: featuredColor, size: 16)
                .padding(.leading, 16)
            Spacer()
            if store.attentionCount > 0 {
                Text("\(store.attentionCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(featuredColor)
                    .padding(.trailing, 16)
            }
        }
        .frame(height: notchHeight)
    }

    // MARK: - 展開：ヘッダー（ウィング配置）＋リッチなセッション行

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            // カメラ帯：左右ウィングにヘッダーを置く（中央はカメラなので空ける）
            HStack {
                HStack(spacing: 6) {
                    PixelBuddy(tint: featuredColor, size: 14)
                    Text("\(store.attentionCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.leading, 16)
                .frame(width: wingWidth, alignment: .leading)

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        zundaVoice.toggle()
                        if zundaVoice { VoiceVox.speakIfEnabled("おしゃべりするのだ") }
                    } label: {
                        Image(systemName: zundaVoice ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(zundaVoice ? Color.green : Color.gray)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("ずんだもん音声")

                    Button {
                        notchApproval.toggle()
                    } label: {
                        Image(systemName: notchApproval ? "checkmark.shield.fill" : "shield.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(notchApproval ? Color.orange : Color.gray)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("ノッチから承認")

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.gray)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("設定")
                }
                .padding(.trailing, 16)
                .frame(width: wingWidth, alignment: .trailing)
            }
            .frame(height: notchHeight)

            // 使用量ストリップ：Claude と Codex の使用率ゲージ（設定で非表示にできる）
            if showUsageStrip {
                usageStrip
            }

            if store.visibleSessions.isEmpty {
                VStack(spacing: 4) {
                    Text("セッションはまだありません")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.gray)
                    Text("Claude Code か Codex を動かすと、ここに表示されます")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                // 30秒ごとに再描画して経過時間バッジを更新
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    VStack(spacing: 5) {
                        ForEach(store.visibleSessions.prefix(ui.showAllSessions ? 8 : 3)) { session in
                            SessionRow(
                                session: session,
                                pending: approval.pending[session.id],
                                onDecide: { allow in onDecide(session.id, allow) },
                                onJump: { FocusJumper.jump(to: session) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }
                if store.visibleSessions.count > 3 {
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            ui.showAllSessions.toggle()
                        }
                    } label: {
                        Text(ui.showAllSessions
                             ? "たたむ ▴"
                             : "ほか \(store.visibleSessions.count - 3) セッション ▾")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 6)
        }
        .transition(.opacity)
    }

    private var wingWidth: CGFloat {
        max(90, (540 - notchWidth) / 2 - 4)
    }

    // Claude / Codex それぞれの 5時間枠・7日枠ゲージ
    private var usageStrip: some View {
        let claudeColor = Color(red: 0.85, green: 0.5, blue: 0.28)
        let codexColor = Color(red: 0.35, green: 0.65, blue: 1.0)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                agentTag("Claude", color: claudeColor)
                if let s = usage.stats {
                    if let p5 = s.claudeOfficial5hPct, let p7 = s.claudeOfficial7dPct {
                        // 公式%（トークン設定済み）
                        gauge(label: "5h", pct: p5, color: claudeColor,
                              detail: "5時間枠(公式): \(p5)%・リセットまで \(UsageFormat.remain(s.claudeOfficial5hReset))")
                        gauge(label: "7d", pct: p7, color: claudeColor,
                              detail: "7日枠(公式): \(p7)%・リセットまで \(UsageFormat.remain(s.claudeOfficial7dReset))")
                        Text("公式")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(claudeColor.opacity(0.9))
                    } else {
                        gauge(label: "5h",
                              pct: budgetPct(tokens: s.claude5hTokens, budgetM: claudeBudget5hM),
                              color: claudeColor,
                              detail: "5時間枠(目安): \(s.claude5hTokens.formatted()) / \(claudeBudget5hM)M tok")
                        gauge(label: "7d",
                              pct: budgetPct(tokens: s.claude7dTokens, budgetM: claudeBudget7dM),
                              color: claudeColor,
                              detail: "7日枠(目安): \(s.claude7dTokens.formatted()) / \(claudeBudget7dM)M tok")
                        Text("目安")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                } else {
                    Text("集計中…").font(.system(size: 9)).foregroundStyle(.gray)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                agentTag("Codex", color: codexColor)
                if let s = usage.stats {
                    if let pct = s.codex5hPct {
                        gauge(label: "5h", pct: pct, color: codexColor,
                              detail: "5時間枠(公式): \(pct)%・リセットまで \(UsageFormat.remain(s.codex5hReset))")
                    }
                    if let pct = s.codex7dPct {
                        gauge(label: "7d", pct: pct, color: codexColor,
                              detail: "7日枠(公式): \(pct)%・リセットまで \(UsageFormat.remain(s.codex7dReset))")
                        if !UsageFormat.remain(s.codex7dReset).isEmpty {
                            Text("残\(UsageFormat.remain(s.codex7dReset))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.gray)
                        }
                    }
                    if s.codex5hPct == nil && s.codex7dPct == nil {
                        Text("データなし（Codex を一度動かすと表示されます）")
                            .font(.system(size: 9)).foregroundStyle(.gray)
                    } else if s.codex5hPct == nil {
                        Text("5h枠なしプラン")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                } else {
                    Text("集計中…").font(.system(size: 9)).foregroundStyle(.gray)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    private func agentTag(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 52, alignment: .leading)
    }

    // 小型ゲージ（バー＋%）
    private func gauge(label: String, pct: Int, color: Color, detail: String) -> some View {
        let clamped = min(max(pct, 0), 100)
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.gray)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(gaugeColor(clamped, base: color))
                    .frame(width: 54 * CGFloat(clamped) / 100)
            }
            .frame(width: 54, height: 5)
            Text("\(pct)%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(gaugeColor(clamped, base: color))
        }
        .help(detail)
    }

    private func gaugeColor(_ pct: Int, base: Color) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return base
    }

    private func budgetPct(tokens: Int, budgetM: Int) -> Int {
        guard budgetM > 0 else { return 0 }
        return Int((Double(tokens) / (Double(budgetM) * 1_000_000) * 100).rounded())
    }
}

// 押した瞬間にきゅっと縮むボタン（即時フィードバック＋スプリング）
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - セッション行（本家流の3行構成）

struct SessionRow: View {
    let session: AgentSession
    let pending: ApprovalCenter.Pending?
    let onDecide: (Bool) -> Void
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 1行目：● プロジェクト · タイトル   [Agent][Host][時間]
            HStack(spacing: 7) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: session.status == .working ? session.status.color.opacity(0.85) : .clear,
                            radius: 3)
                Text(titleLine)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !session.title.isEmpty, session.title != session.projectName {
                    Text(session.projectName)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Spacer()
                badge(session.agent.label, color: agentColor)
                badge(session.hostAppLabel, color: .gray)
                badge(session.timeAgoLabel, color: .gray)
            }

            // 2行目：あなた：最後の指示
            if !session.lastUserPrompt.isEmpty {
                HStack(spacing: 4) {
                    Text("あなた：")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(session.lastUserPrompt)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            // 3行目：状態の詳細（返答プレビュー or 実行中ツール）
            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.system(size: 9.5))
                    .foregroundStyle(statusLineColor)
                    .lineLimit(1)
            }

            // 承認保留中は [許可][拒否]
            if let pending {
                HStack(spacing: 6) {
                    Text(pending.toolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                    Text(pending.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                    Spacer()
                    Button { onDecide(true) } label: {
                        Text("許可")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.gradient))
                    }
                    .buttonStyle(PressableButtonStyle())
                    Button { onDecide(false) } label: {
                        Text("拒否")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.85).gradient))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(pending != nil
                      ? Color.orange.opacity(0.13)
                      : Color.white.opacity(hovering ? 0.12 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.10 : 0), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) { hovering = h }
        }
        .onTapGesture(perform: onJump)
    }

    // セッション名を主役に。無ければプロジェクト名
    private var titleLine: String {
        session.title.isEmpty ? session.projectName : session.title
    }

    private var agentColor: Color {
        session.agent == .claudeCode
            ? Color(red: 0.85, green: 0.5, blue: 0.28)
            : Color(red: 0.35, green: 0.65, blue: 1.0)
    }

    private var statusLine: String {
        switch session.status {
        case .working: return session.lastMessage
        case .done, .idle: return session.lastReply
        case .waitingApproval: return ""
        }
    }

    private var statusLineColor: Color {
        session.status == .working
            ? Color.cyan.opacity(0.75)
            : Color.white.opacity(0.4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color == .gray ? Color.white.opacity(0.6) : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(color == .gray ? 0.18 : 0.35)))
    }
}
