import AppKit
import ServiceManagement
import SwiftUI

// 歯車から開く設定ウィンドウ
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView()
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "ずんだノッチ設定"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 460, height: 700))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @AppStorage("zundaVoiceEnabled") private var zundaVoice = true
    @AppStorage("notchApprovalEnabled") private var notchApproval = true
    @AppStorage("soundEffectsEnabled") private var soundEffects = true
    @AppStorage("autoExpandOnEvent") private var autoExpand = true
    @AppStorage("silentHoursEnabled") private var silentHours = false
    @AppStorage("claudeBudget5hM") private var claudeBudget5hM = 15
    @AppStorage("claudeBudget7dM") private var claudeBudget7dM = 500
    @AppStorage("showUsageStrip") private var showUsageStrip = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError = ""
    @State private var tokenInput = ""
    @State private var tokenConfigured = ClaudeToken.isConfigured
    @ObservedObject private var usage = UsageMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    Toggle("ずんだもん音声", isOn: $zundaVoice)
                    caption("完了時に「できたのだ！」、承認待ちに「許可がほしいのだ！」と読み上げます。")
                    Toggle("サウンドエフェクト", isOn: $soundEffects)
                    caption("音声がオフのときは、短い効果音でお知らせします。")
                    Toggle("通知でパネルを自動展開", isOn: $autoExpand)
                    caption("オフにするとパネルは閉じたまま、ノッチがそっと光ります。承認だけは自動で展開します。")
                } header: { sectionHeader("通知", "bell.badge.fill") }

                Section {
                    Toggle(isOn: $showUsageStrip) {
                        HStack(spacing: 6) {
                            Text("ノッチに使用量ゲージを表示")
                            betaBadge
                        }
                    }
                    caption("Claude / Codex の使用率バーをノッチに表示します。実験的な機能のため、初期状態ではオフになっています。")
                    if let s = usage.stats {
                        usageRows(s)
                        caption("最終更新：\(s.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        caption("集計中…")
                    }
                    Button("いますぐ更新") { usage.refresh() }
                } header: { sectionHeader("使用量ゲージ", "gauge.with.dots.needle.bottom.50percent") }

                Section {
                    if tokenConfigured {
                        HStack {
                            Label("公式トークン設定済み", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("削除") {
                                ClaudeToken.delete()
                                tokenConfigured = false
                                usage.refresh()
                            }
                        }
                        caption("Claude ゲージを公式％で表示しています。")
                    } else {
                        SecureField("sk-ant-oat01-… を貼り付け", text: $tokenInput)
                        Button("Keychain に保存") {
                            if ClaudeToken.save(tokenInput) {
                                tokenInput = ""
                                tokenConfigured = true
                                usage.refresh()
                            }
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        caption("ターミナルで claude setup-token を実行し、ブラウザで承認して表示されたトークンを貼り付けてください。Mac の Keychain に保存され、Anthropic 公式 API への問い合わせにのみ使用します（外部への送信・表示は一切ありません）。")
                    }
                } header: { sectionHeader("Claude 公式％を有効にする（任意）", "key.fill") }

                Section {
                    Stepper(value: $claudeBudget5hM, in: 1...100) {
                        LabeledContent("5時間枠の目安", value: "\(claudeBudget5hM)M tok")
                    }
                    Stepper(value: $claudeBudget7dM, in: 10...2000, step: 10) {
                        LabeledContent("7日枠の目安", value: "\(claudeBudget7dM)M tok")
                    }
                    caption("この環境では Claude の公式上限％を取得できないため、実測トークンをこの目安で割ってゲージを描きます。Codex は公式％をそのまま表示します。")
                } header: { sectionHeader("Claude ゲージの目安上限", "slider.horizontal.3") }

                Section {
                    Toggle("指定した時間帯はミュート", isOn: $silentHours)
                    if silentHours {
                        DatePicker("開始", selection: timeBinding("silentStartMinutes"),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("終了", selection: timeBinding("silentEndMinutes"),
                                   displayedComponents: .hourAndMinute)
                        caption("この時間帯はずんだもん音声も効果音も鳴りません（ノッチの表示は動きます）。")
                    }
                } header: { sectionHeader("サイレント時間帯", "moon.fill") }

                Section {
                    Toggle("ノッチから承認（許可 / 拒否ボタン）", isOn: $notchApproval)
                    caption("オフにすると、これまで通りターミナル側で確認します。\(Int(ApprovalCenter.autoReleaseSeconds))秒応答がないときも、自動でターミナルに戻ります。")
                } header: { sectionHeader("承認", "checkmark.shield.fill") }

                Section {
                    Toggle("ログイン時に自動起動", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                loginItemError = ""
                            } catch {
                                loginItemError = "設定できませんでした：\(error.localizedDescription)"
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    if !loginItemError.isEmpty {
                        Text(loginItemError).font(.caption).foregroundStyle(.red)
                    }
                } header: { sectionHeader("起動", "power") }

                Section {
                    LabeledContent("バージョン", value: "1.1")
                    LabeledContent("対応エージェント", value: "Claude Code / Codex")
                    caption("音声：VOICEVOX ずんだもん")
                    caption("Claude Code hooks・Codex notify 経由でローカル完結。クラウドへの送信はありません。")
                } header: { sectionHeader("情報", "info.circle.fill") }

                Section {
                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("ずんだノッチを終了", systemImage: "power")
                            .frame(maxWidth: .infinity)
                    }
                    caption("ノッチから完全に終了します。次回は Launchpad か「open -a ずんだノッチ」で起動できます。")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .animation(.spring(response: 0.35, dampingFraction: 1.0), value: silentHours)
            .animation(.spring(response: 0.35, dampingFraction: 1.0), value: tokenConfigured)
        }
        .frame(width: 460, height: 700)
        .background(.background)
    }

    // MARK: - ヘッダー（枝豆アイコン＋アプリ名）

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("ずんだノッチ")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Claude Code と Codex を、ノッチで見守る。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.72, blue: 0.33).opacity(0.16), .clear],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - パーツ

    private var betaBadge: some View {
        Text("ベータ")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.gradient))
    }

    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func usageRows(_ s: UsageStats) -> some View {
        if let p5 = s.claudeOfficial5hPct {
            LabeledContent("Claude 5時間枠（公式）") {
                Text("\(p5)%・残 \(UsageFormat.remain(s.claudeOfficial5hReset))")
            }
        } else {
            LabeledContent("Claude 5時間枠") {
                Text("\(TokenFormat.short(s.claude5hTokens)) tok 使用")
            }
        }
        if let p7 = s.claudeOfficial7dPct {
            LabeledContent("Claude 7日枠（公式）") {
                Text("\(p7)%・残 \(UsageFormat.remain(s.claudeOfficial7dReset))")
            }
        } else {
            LabeledContent("Claude 7日枠") {
                Text("\(TokenFormat.short(s.claude7dTokens)) tok 使用")
            }
        }
        if let pct = s.codex7dPct {
            LabeledContent("Codex 7日枠（公式）") {
                Text("\(pct)%・残 \(UsageFormat.remain(s.codex7dReset))")
            }
        }
        if let pct = s.codex5hPct {
            LabeledContent("Codex 5時間枠（公式）") {
                Text("\(pct)%・残 \(UsageFormat.remain(s.codex5hReset))")
            }
        }
    }

    // 「HH:mm」⇔ 深夜0時からの分数（UserDefaults保存用）
    private func timeBinding(_ key: String) -> Binding<Date> {
        Binding {
            let minutes = UserDefaults.standard.integer(forKey: key)
            return Calendar.current.date(
                bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
            ) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            UserDefaults.standard.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: key)
        }
    }
}
