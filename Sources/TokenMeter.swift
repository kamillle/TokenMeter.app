import AppKit
import SwiftUI
import ServiceManagement
func compact(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return String(n)
}
func money(_ cost: Double?) -> String {
    guard let cost else { return "単価未設定" }
    return String(format: cost < 0.01 && cost > 0 ? "≈ $%.4f" : "≈ $%.2f", cost)
}
func dateText(_ time: Double) -> String {
    guard time > 0 else { return "未取得" }
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d HH:mm"
    return f.string(from: Date(timeIntervalSince1970: time))
}
func providerColor(_ provider: String) -> Color {
    provider == "codex" ? Color(red: 0.12, green: 0.57, blue: 0.49) : Color(red: 0.76, green: 0.42, blue: 0.29)
}
let sessionMetricWidth: CGFloat = 82

enum PanelLayout {
    static let width: CGFloat = 920
    static let height: CGFloat = 980
}

// User-selected PNGs are bundled locally; AppKit adapts the black mark to the menu-bar appearance.
func brandImage(_ provider: String, size: CGFloat = 18) -> NSImage {
    let name = provider == "codex" ? "chatgpt-logo" : "claude-logo"
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let image = NSImage(contentsOf: url) else {
        return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: "Logo unavailable") ?? NSImage()
    }
    image.size = NSSize(width: size, height: size)
    image.isTemplate = provider == "codex"
    return image
}

func appIconImage(size: CGFloat = 28) -> NSImage {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let image = NSImage(contentsOf: url) else {
        return NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "TokenMeter") ?? NSImage()
    }
    image.size = NSSize(width: size, height: size)
    return image
}

@MainActor final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var selected = "codex"
    @Published var loading = false
    @Published var failure = ""
    @Published var notice = ""
    @Published var filter = ""
    @Published var days = 30
    @Published var sessionSort: SessionSort?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var pricingChecking = false
    @Published var pricingStatus = PricingCheckStatus()
    @Published var lastCodexAccountID: String?
    @Published var page = "usage"
    @Published var providerStatuses: [ProviderStatus] = []
    @Published var issueDemoActive = false
    var hasStatusIssue: Bool { issueDemoActive || providerStatuses.contains(where: \.hasIssue) }
    @Published var statusLoading = false
    @Published var statusErrors: [String] = []
    @Published var statusUpdated: Double = 0
    var onUpdate: (() -> Void)?
    let collector = UsageCollector()
    let bridgeManager = BridgeManager()
    let pricingUpdater = OfficialPricingUpdater()
    init() {
        lastCodexAccountID = collector.cachedCodexAccountID()
        pricingStatus = pricingUpdater.readStatus()
    }
    func quota(_ provider: String) -> Quota {
        var quota = (provider == "codex" ? snapshot?.codex : snapshot?.claude) ?? .empty
        if provider == "codex", quota.accountID == nil { quota.accountID = lastCodexAccountID }
        return quota
    }
    func isLinked(_ provider: String) -> Bool {
        let q = quota(provider)
        if let linked = q.linked { return linked }
        if provider == "claude" { return q.bridgeInstalled == true }
        return !q.windows.isEmpty || (snapshot?.sessions.contains { $0.provider == provider } == true)
    }
    var sessions: [Session] {
        let cutoff = days == 1 ? Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 : Date().timeIntervalSince1970 - Double(days) * 86400
        let filtered = (snapshot?.sessions ?? []).filter {
            $0.provider == selected && $0.updated >= cutoff &&
            (filter.isEmpty || ($0.title + $0.cwd + $0.id + $0.models.map(\.model).joined()).localizedCaseInsensitiveContains(filter))
        }
        return sortedSessions(filtered, by: sessionSort)
    }
    func toggleSort(_ key: SessionSortKey) {
        sessionSort = nextSessionSort(current: sessionSort, key: key)
    }
    func refresh(force: Bool = false) {
        guard !loading else { return }
        loading = true
        let collector = collector
        let bridgeManager = bridgeManager
        DispatchQueue.global(qos: .utility).async {
            bridgeManager.migrateLegacyBridgeIfNeeded()
            let result = Result { try collector.collect(force: force) }
            DispatchQueue.main.async {
                self.loading = false
                if case .success(let snapshot) = result {
                    self.snapshot = snapshot
                    self.lastCodexAccountID = snapshot.codex.accountID ?? self.lastCodexAccountID
                    self.failure = ""
                }
                else { self.failure = "集計を更新できませんでした。前回の値を表示しています" }
                self.onUpdate?()
            }
        }
    }
    func bridge(remove: Bool = false) {
        let bridgeManager = bridgeManager
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try bridgeManager.setup(remove: remove) }
            DispatchQueue.main.async {
                switch result {
                case .success(let message): self.notice = message
                case .failure(let error): self.notice = error.localizedDescription
                }
                self.refresh()
            }
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { notice = "ログイン項目を設定できません。アプリをApplicationsフォルダに置いてから再度お試しください" }
    }
    func checkPrices(force: Bool = false) {
        guard !pricingChecking else { return }
        if !force && !pricingUpdater.isDue() { return }
        pricingChecking = true
        let updater = pricingUpdater
        Task {
            let outcome = await updater.check(force: force)
            await MainActor.run {
                self.pricingChecking = false
                switch outcome {
                case .skipped:
                    self.pricingStatus = updater.readStatus()
                case .unchanged(let status):
                    self.pricingStatus = status
                    if force { self.notice = status.message }
                case .updated(let status, _):
                    self.pricingStatus = status
                    self.notice = status.message
                    self.refresh()
                case .failed(let status):
                    self.pricingStatus = status
                    if force { self.notice = status.message }
                }
            }
        }
    }
    func refreshStatus() {
        guard !statusLoading else { return }
        statusLoading = true
        Task {
            let result = await ProviderStatusService().fetch()
            await MainActor.run {
                if !result.0.isEmpty {
                    for provider in result.0 {
                        if let index = self.providerStatuses.firstIndex(where: { $0.id == provider.id }) {
                            self.providerStatuses[index] = provider
                        } else {
                            self.providerStatuses.append(provider)
                        }
                    }
                    self.providerStatuses.sort { $0.id > $1.id }
                    self.statusUpdated = Date().timeIntervalSince1970
                }
                self.statusErrors = result.1
                self.statusLoading = false
                self.onUpdate?()
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    @State private var hoveringSummaryInfo = false
    @State private var showingSummaryInfo = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A tab's minimum content height must never move the shared header.
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    usageContent
                        .opacity(store.page == "usage" ? 1 : 0)
                        .allowsHitTesting(store.page == "usage")
                        .accessibilityHidden(store.page != "usage")

                    StatusPanel(store: store)
                        .opacity(store.page == "status" ? 1 : 0)
                        .allowsHitTesting(store.page == "status")
                        .accessibilityHidden(store.page != "status")
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: appIconImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityLabel("TokenMeter")
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenMeter").font(.system(size: 19, weight: .bold, design: .rounded))
                Text("AIの利用状況を、ひと目で").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            pageTabs
            Spacer()
            if store.page == "usage" ? store.loading : store.statusLoading { ProgressView().controlSize(.small) }
            Button {
                if store.page == "usage" { store.refresh(force: true) }
                else { store.refreshStatus() }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain)
            .disabled(store.page == "usage" ? store.loading : store.statusLoading)
            .help(store.page == "usage" ? "使用状況を更新" : "プロバイダーステータスを更新")
            Menu {
                Button("ログイン時に起動 " + (store.loginEnabled ? "✓" : "")) { store.toggleLogin() }
                Button("Claude連携を" + (store.quota("claude").bridgeInstalled == true ? "解除" : "有効にする")) { store.bridge(remove: store.quota("claude").bridgeInstalled == true) }
                Divider()
                Button("TokenMeterを終了") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .frame(height: 58, alignment: .top)
    }

    private var pageTabs: some View {
        HStack(spacing: 2) {
            pageButton("usage", "TokenMeter", icon: "chart.bar.xaxis")
            pageButton("status", "Status", icon: "waveform.path.ecg")
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                providerButton("codex", "Codex")
                providerButton("claude", "Claude")
            }.padding(.horizontal, 22).padding(.bottom, 12)

            // Keep unusually long errors or extra quota windows from displacing the session list.
            ScrollView {
                quotaCard
                if !store.failure.isEmpty {
                    Label(store.failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                if !store.notice.isEmpty {
                    HStack(alignment: .top) {
                        Text(store.notice).font(.system(size: 11))
                        Spacer()
                        Button { store.notice = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("お知らせを閉じる")
                    }.padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxHeight: 218)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)

            sessionToolbar
            sessionColumns
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.sessions.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: store.filter.isEmpty ? "tray" : "magnifyingglass")
                                .font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(store.loading ? "セッションを集計しています…" : "該当するセッションがありません")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            if store.loading {
                                Text("初回は過去のログを読み込みます").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 34)
                    }
                    ForEach(store.sessions) { session in SessionRow(session: session) }
                }.padding(.horizontal, 22).padding(.bottom, 8)
            }.frame(minHeight: 80, maxHeight: .infinity)
            sessionSummary
        }
    }

    private var sessionToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Text("セッション").font(.system(size: 15, weight: .semibold))
                Text("\(store.sessions.count)")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
                Text("最終更新日").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("最終更新日", selection: $store.days) {
                    Text("今日更新").tag(1); Text("7日以内").tag(7); Text("30日以内").tag(30)
                }.labelsHidden().frame(width: 100).controlSize(.small)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("セッション・モデル・プロジェクトを検索", text: $store.filter)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !store.filter.isEmpty {
                    Button { store.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("検索をクリア")
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
    }

    private var sessionColumns: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("各セッションの累計")
                if store.sessionSort != nil {
                    Button { store.sessionSort = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).foregroundStyle(providerColor(store.selected))
                        .help("並び替えをクリアして更新日時順に戻す")
                        .accessibilityLabel("並び替えをクリア")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            sortButton("入力", key: .input, width: sessionMetricWidth)
            sortButton("出力", key: .output, width: sessionMetricWidth)
            sortButton("参考 USD", key: .cost, width: sessionMetricWidth)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 22)
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("表示中の累計")
                        Button { showingSummaryInfo.toggle() } label: {
                            Image(systemName: "info.circle")
                                .frame(width: 20, height: 16)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .onHover { hoveringSummaryInfo = $0 }
                            .accessibilityLabel("トークン数と参考料金の説明")
                            .overlay(alignment: .bottomLeading) {
                                if hoveringSummaryInfo || showingSummaryInfo {
                                    Text("API標準・短コンテキストの概算。サブスクの追加請求ではありません。入力はキャッシュ込み。Fast／Priority・長文割増・地域・ツール料金等は対象外。")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                        .frame(width: 330, alignment: .leading)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
                                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                                        .offset(y: -24)
                                        .allowsHitTesting(false)
                                }
                            }
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text("\(store.sessions.count) セッション").font(.system(size: 12, weight: .medium))
                }.frame(maxWidth: .infinity, alignment: .leading)
                summaryMetric("入力", compact(store.sessions.reduce(0) { $0 + $1.input }))
                summaryMetric("出力", compact(store.sessions.reduce(0) { $0 + $1.output }))
                summaryMetric("参考 USD", money(store.sessions.reduce(0) { $0 + $1.knownCost }) + (store.sessions.contains { $0.cost == nil } ? " + 未算定" : ""))
            }
            if let errors = store.snapshot?.errors, !errors.isEmpty {
                Text(errors.joined(separator: " / ")).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                    .help(errors.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
        .zIndex(1)
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }.frame(width: title == "参考 USD" ? 158 : sessionMetricWidth, alignment: .trailing).padding(.leading, 12)
    }
    func pageButton(_ id: String, _ title: String, icon: String) -> some View {
        let active = store.page == id
        let hasIssue = id == "status" && store.hasStatusIssue
        return Button {
            let switched = store.page != id
            store.page = id
            if id == "status", switched { store.refreshStatus() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(active ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if hasIssue {
                        Circle().fill(Color.red).frame(width: 6, height: 6).padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title + "に切り替え")
        .accessibilityLabel(title)
        .accessibilityValue(hasIssue ? (store.issueDemoActive ? "障害表示テスト中" : "障害情報あり") : "")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
    func sortButton(_ title: String, key: SessionSortKey, width: CGFloat) -> some View {
        let active = store.sessionSort?.key == key
        let ascending = active && store.sessionSort?.direction == .ascending
        return Button { store.toggleSort(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: active ? (ascending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(active ? providerColor(store.selected) : Color.secondary.opacity(0.55))
                    .frame(width: 10, height: 10)
            }.frame(width: width, alignment: .trailing).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title + (active ? (ascending ? "：昇順。クリックで降順" : "：降順。クリックで昇順") : "で並び替え"))
        .accessibilityLabel(title + "で並び替え")
        .accessibilityValue(active ? (ascending ? "昇順" : "降順") : "未選択")
    }
    func providerButton(_ id: String, _ title: String) -> some View {
        let active = store.selected == id
        let q = store.quota(id)
        return Button { store.selected = id; store.filter = "" } label: {
            HStack(spacing: 9) {
                Image(nsImage: brandImage(id)).renderingMode(id == "codex" ? .template : .original)
                    .resizable().frame(width: 20, height: 20).foregroundStyle(Color.primary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.primary)
                Spacer()
                if let limit = q.limiting {
                    Text(String(format: "残り %.0f%%", limit.remaining) + (q.stale ? " ·" : ""))
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                } else {
                    Text("未取得").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if active { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)) }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .foregroundStyle(active ? providerColor(id) : Color.secondary)
            .background(active ? providerColor(id).opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? providerColor(id).opacity(0.55) : Color.primary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    var quotaCard: some View {
        let q = store.quota(store.selected)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("残り利用枠").font(.system(size: 13, weight: .semibold))
                Spacer()
                if q.stale && q.observed > 0 {
                    Label("古い取得値 · " + dateText(q.observed), systemImage: "clock.badge.exclamationmark")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Group {
                HStack(spacing: 6) {
                    Text("アカウントID").foregroundStyle(.secondary)
                    Text(q.accountID ?? "未取得").lineLimit(1).textSelection(.enabled)
                        .help(q.accountID ?? "未取得")
                }.font(.system(size: 11))
            }
            if q.windows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.loading && store.snapshot == nil ? "読み込み中…" : "利用枠は未取得")
                        .font(.system(size: 22, weight: .semibold))
                    if !q.detail.isEmpty { Text(q.detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(q.windows.filter { $0.bucket == "codex" || $0.bucket == "claude" }) { window in
                        QuotaWindowCard(window: window, provider: store.selected)
                    }
                }
            }
            if q.windows.contains(where: { $0.bucket != "codex" && $0.bucket != "claude" }) {
                DisclosureGroup("ほかのモデル別利用枠") {
                    ForEach(q.windows.filter { $0.bucket != "codex" && $0.bucket != "claude" }) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(w.label); Spacer(); Text(w.expired ? "更新待ち" : String(format: "残り %.0f%%", w.remaining)) }
                            Text(w.resetsAt > 0 ? "リセット " + dateText(w.resetsAt) : "リセット時刻未取得")
                                .foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }.font(.system(size: 11))
            }
            if !q.error.isEmpty {
                Label(q.error + " · ログの最終取得値で補完", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if store.selected == "claude" && q.windows.isEmpty {
                HStack {
                    if q.bridgeInstalled != true { Button("Claude連携を有効にする") { store.bridge() }.controlSize(.small) }
                    Button("Claudeの利用状況を開く") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }.controlSize(.small)
                }
            }
        }
    }
}

struct QuotaWindowCard: View {
    let window: LimitWindow
    let provider: String
    private var tint: Color {
        window.expired ? .secondary : (window.remaining < 15 ? .orange : providerColor(provider))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(window.label).font(.system(size: 12, weight: .medium))
                    if !window.expired && window.remaining < 15 {
                        Text("残りわずか").font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
                    }
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.expired ? "更新待ち" : String(format: "%.0f", window.remaining))
                    .font(.system(size: window.expired ? 23 : 32, weight: .semibold, design: .rounded)).monospacedDigit()
                if !window.expired { Text("%").font(.system(size: 17, weight: .medium)) }
                }.foregroundStyle(tint)
            }.frame(height: 40)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(tint).frame(width: proxy.size.width * (window.expired ? 0 : min(100, max(0, window.remaining)) / 100))
                }
            }.frame(height: 6).accessibilityHidden(true)
            Text(window.resetsAt > 0 ? "リセット " + dateText(window.resetsAt) : "リセット時刻未取得")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.20)))
    }
}

struct StatusPanel: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("プロバイダー ステータス").font(.system(size: 15, weight: .semibold))
                        Text("OpenAIとAnthropicの公式稼働情報").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.statusUpdated > 0 {
                        Text("取得 " + dateText(store.statusUpdated)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }

                if store.providerStatuses.isEmpty {
                    VStack(spacing: 10) {
                        if store.statusLoading { ProgressView().controlSize(.small) }
                        Image(systemName: store.statusLoading ? "network" : "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 27)).foregroundStyle(.tertiary)
                        Text(store.statusLoading ? "公式ステータスを取得しています…" : "ステータスを取得できませんでした")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                }

                ForEach(store.providerStatuses) { provider in
                    ProviderStatusCard(provider: provider)
                }

                if !store.statusErrors.isEmpty {
                    Text(store.statusErrors.joined(separator: "\n"))
                        .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }

                Text("起動時・5分ごと・Statusタブを開いたとき・手動更新時に各社の公開ステータスを確認します。表示は全ユーザー・全機能の個別状況を保証するものではありません。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }
}

struct ProviderStatusCard: View {
    let provider: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: brandImage(provider.id == "openai" ? "codex" : "claude", size: 20))
                    .renderingMode(provider.id == "openai" ? .template : .original)
                    .resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.system(size: 14, weight: .semibold))
                    Text(statusLabel(provider.indicator, fallback: provider.description))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor(provider.indicator))
                }
                Spacer()
                Button("公式ページ") {
                    if let url = URL(string: provider.url) { NSWorkspace.shared.open(url) }
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if provider.incidents.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("進行中のインシデントはありません").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("進行中のインシデント  \(provider.incidents.count)件")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    ForEach(provider.incidents) { incident in
                        Button {
                            if let url = URL(string: incident.url) { NSWorkspace.shared.open(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle().fill(statusColor(incident.impact)).frame(width: 7, height: 7)
                                    Text(incident.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                    Spacer()
                                    Text(incidentStatusLabel(incident.status)).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                if !incident.message.isEmpty {
                                    Text(incident.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
                                }
                                if incident.updated > 0 {
                                    Text("更新 " + dateText(incident.updated)).font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("関連サービス").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(provider.relevantComponents) { component in
                    HStack(spacing: 7) {
                        Circle().fill(statusColor(component.status)).frame(width: 7, height: 7)
                        Text(component.name).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        Text(componentStatusLabel(component.status)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(provider.hasIssue ? Color.orange.opacity(0.30) : .clear))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "none", "operational": return .green
        case "minor", "degraded_performance", "monitoring": return .yellow
        case "major", "partial_outage", "identified", "investigating": return .orange
        case "critical", "major_outage": return .red
        default: return .secondary
        }
    }

    private func statusLabel(_ indicator: String, fallback: String) -> String {
        switch indicator {
        case "none": return "正常稼働"
        case "minor": return "一部で性能低下"
        case "major": return "部分的な障害"
        case "critical": return "重大な障害"
        default: return fallback
        }
    }

    private func componentStatusLabel(_ status: String) -> String {
        switch status {
        case "operational": return "正常"
        case "degraded_performance": return "性能低下"
        case "partial_outage": return "部分障害"
        case "major_outage": return "重大障害"
        case "under_maintenance": return "メンテナンス"
        default: return status
        }
    }

    private func incidentStatusLabel(_ status: String) -> String {
        switch status {
        case "investigating": return "調査中"
        case "identified": return "原因特定"
        case "monitoring": return "監視中"
        default: return status
        }
    }
}

struct SessionRow: View {
    let session: Session
    @State private var expanded = CommandLine.arguments.contains("--render") && CommandLine.arguments.contains("--expanded")
    @State private var hovered = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Button { withAnimation(.easeInOut(duration:0.15)) { expanded.toggle() } } label: {
                HStack(spacing:0) {
                    VStack(alignment:.leading,spacing:5) {
                        HStack(spacing:5) {
                            Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                            Text(session.title).lineLimit(1).help(session.title).font(.system(size:13,weight:.medium))
                            if session.members.count > 1 {
                                let subAgentCount = session.members.count - 1
                                Text("\(subAgentCount) sub agent\(subAgentCount == 1 ? "" : "s")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                            }
                        }
                        Text(dateText(session.updated) + " · " + session.models.map(\.model).joined(separator:", ")).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Text(compact(session.input)).frame(width:sessionMetricWidth,alignment:.trailing)
                    Text(compact(session.output)).frame(width:sessionMetricWidth,alignment:.trailing)
                    Text(money(session.cost)).foregroundStyle(session.cost == nil ? Color.secondary : providerColor(session.provider)).frame(width:sessionMetricWidth,alignment:.trailing)
                }.font(.system(size:12)).monospacedDigit().contentShape(Rectangle()).padding(.horizontal,12).padding(.vertical,12)
            }.buttonStyle(.plain).accessibilityLabel(session.title + "、詳細を" + (expanded ? "閉じる" : "開く"))
            if expanded {
                VStack(alignment:.leading,spacing:8) {
                    Text(session.cwd.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let parentID = session.parentID {
                        Text("親タスクID: " + parentID).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if session.members.count > 1 {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("タスク内訳（一覧は親子の合計）").frame(maxWidth: .infinity, alignment: .leading)
                                Text("入力").frame(width: 70, alignment: .trailing)
                                Text("出力").frame(width: 58, alignment: .trailing)
                                Text("参考 USD").frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.bottom, 5)
                            ForEach(Array(session.members.enumerated()), id: \.element.id) { offset, member in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(memberTitle(member, offset: offset)).lineLimit(1)
                                        Text(member.models.map(\.model).joined(separator: ", "))
                                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                        if let parentID = member.parentID {
                                            Text("親: " + parentTitle(parentID)).font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                        Button("ID: " + String(member.id.prefix(8)) + "… をコピー") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(member.id, forType: .string)
                                        }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary)
                                            .help(member.id).accessibilityLabel("タスクIDをコピー: " + member.id)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(compact(member.input)).frame(width: 70, alignment: .trailing)
                                    Text(compact(member.output)).frame(width: 58, alignment: .trailing)
                                    Text(money(member.cost)).frame(width: 70, alignment: .trailing)
                                        .foregroundStyle(member.cost == nil ? Color.secondary : providerColor(session.provider))
                                }
                                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                                .padding(.vertical, 4)
                                if offset < session.members.count - 1 { Divider() }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                    }
                    HStack {
                        detail("入力（キャッシュ込）", session.input)
                        detail("出力", session.output)
                        detail("キャッシュ読取", session.cached)
                        detail("キャッシュ書込", session.write)
                    }
                    ForEach(session.models) { m in
                        HStack { Text(m.model); Spacer(); Text(money(m.cost)) }.font(.system(size:10,design:.monospaced))
                    }
                    if !session.unknownModels.isEmpty {
                        Text("単価未設定: " + session.unknownModels.joined(separator:", ") + "。歯車メニューから単価を追加できます。").font(.system(size:11)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text(String(session.id.prefix(18)) + "…").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button("IDをコピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id,forType:.string) }.buttonStyle(.plain).font(.system(size:11))
                    }
                }.padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius:8)).padding(.horizontal,8).padding(.bottom,8).textSelection(.enabled)
            }
        }
        .background(Color.primary.opacity(expanded ? 0.045 : (hovered ? 0.035 : 0)), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 12) }
        .onHover { hovered = $0 }
    }
    func detail(_ title: String, _ value: Int64) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.system(size:11)).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size:11,weight:.medium,design:.monospaced))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func memberTitle(_ member: SessionMemberUsage, offset: Int) -> String {
        if offset == 0 { return "親タスク" }
        let base = "子タスク \(offset)"
        guard let name = member.agentName, !name.isEmpty else { return base }
        return base + " · " + name
    }
    func parentTitle(_ id: String) -> String {
        guard let offset = session.members.firstIndex(where: { $0.id == id }) else { return id }
        return memberTitle(session.members[offset], offset: offset)
    }
}

@MainActor final class IssueIndicatorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    var timer: Timer?
    var pricingTimer: Timer?
    var providerStatusTimer: Timer?
    var issueBlinkTimer: Timer?
    let issueDot = IssueIndicatorView(frame: NSRect(x: 4, y: 0, width: 7, height: 7))
    var previewWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let pos = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > pos + 2 {
            let input = URL(fileURLWithPath: CommandLine.arguments[pos + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[pos + 2])
            if let data = try? Data(contentsOf: input), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                store.snapshot = snapshot
                if CommandLine.arguments.contains("--claude") { store.selected = "claude" }
                if CommandLine.arguments.contains("--status") { store.page = "status"; store.refreshStatus() }
                let view = NSHostingView(rootView: Panel(store: store))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                if CommandLine.arguments.contains("--dark") { view.appearance = NSAppearance(named: .darkAqua) }
                window.orderFront(nil)
                view.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height)
                view.layoutSubtreeIfNeeded()
                let renderDelay = CommandLine.arguments.contains("--status") ? 3.0 : 0.6
                DispatchQueue.main.asyncAfter(deadline: .now() + renderDelay) {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: output) }
                    }
                    NSApp.terminate(nil)
                }
                return
            }
        }
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--preview") ? .regular : .accessory)
        // Detect duplicate instances using the application bundle identity.
        if NSRunningApplication.runningApplications(withBundleIdentifier:"local.tokenmeter.TokenMeter").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 { NSApp.terminate(nil); return }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: PanelLayout.width, height: PanelLayout.height)
        popover.contentViewController = NSHostingController(rootView:Panel(store:store))
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "TokenMeter")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("TokenMeter")
        }
        issueDot.wantsLayer = true
        issueDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        issueDot.layer?.cornerRadius = 3.5
        issueDot.isHidden = true
        item.button?.addSubview(issueDot)
        statusItem = item
        store.onUpdate = { [weak self] in self?.updateStatus() }
        if CommandLine.arguments.contains("--demo-issue") {
            store.issueDemoActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.store.issueDemoActive = false
                self?.updateStatus()
            }
            updateStatus()
        }
        store.refresh()
        store.checkPrices()
        store.refreshStatus()
        let statusTimer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refreshStatus() }
        }
        RunLoop.main.add(statusTimer, forMode: .common)
        providerStatusTimer = statusTimer
        timer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        pricingTimer = Timer.scheduledTimer(withTimeInterval:60 * 60,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.store.checkPrices() }
        }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:PanelLayout.width,height:PanelLayout.height),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "TokenMeter"; window.contentView = NSHostingView(rootView:Panel(store:store)); window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window; NSApp.activate(ignoringOtherApps:true)
        }
    }
    func updateStatus() {
        guard let button = statusItem?.button else { return }
        defer { updateIssueIndicator() }
        let providers = ["codex", "claude"].filter { store.isLinked($0) }
        guard let first = providers.first else {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "TokenMeter")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "連携中のアカウントはありません\nクリックして設定を開く"
            button.setAccessibilityLabel("TokenMeter · 連携中のアカウントなし")
            return
        }

        button.image = brandImage(first)
        button.imagePosition = .imageLeading
        let title = NSMutableAttributedString()
        var descriptions: [String] = []
        for (index, provider) in providers.enumerated() {
            let q = store.quota(provider)
            let value: String
            if let w = q.limiting {
                value = String(format:"%.0f%%",w.remaining) + (q.stale || !store.failure.isEmpty ? "·" : "")
                descriptions.append(provider.capitalized + " 残り " + String(format:"%.0f%%",w.remaining) + "（" + w.label + "） · " + q.source + " · " + dateText(q.observed))
            } else {
                value = "—"
                descriptions.append(provider.capitalized + " · 利用枠未取得")
            }
            if index > 0 {
                title.append(NSAttributedString(string: "   "))
                let attachment = NSTextAttachment()
                attachment.image = brandImage(provider, size: 16)
                attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " " + value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            ]))
        }
        button.attributedTitle = title
        button.toolTip = descriptions.joined(separator: "\n") + "\nクリックして詳細を見る"
        button.setAccessibilityLabel(descriptions.joined(separator: "、"))
    }
    private func updateIssueIndicator() {
        guard let button = statusItem?.button else { return }
        let isDemo = store.issueDemoActive
        let hasIssue = store.hasStatusIssue
        issueDot.isHidden = !hasIssue
        guard hasIssue else {
            issueBlinkTimer?.invalidate()
            issueBlinkTimer = nil
            issueDot.alphaValue = 1
            return
        }
        // Reserve space before the original image while preserving its template/color behavior.
        if let original = button.image {
            let padded = NSImage(size: NSSize(width: original.size.width + 12, height: original.size.height))
            padded.lockFocus()
            original.draw(at: NSPoint(x: 12, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            padded.unlockFocus()
            padded.isTemplate = original.isTemplate
            button.image = padded
        }
        issueDot.frame.origin.y = (button.bounds.height - issueDot.frame.height) / 2
        let issueLabel = isDemo ? "赤い丸の点滅テスト（60秒）" : "障害情報あり（Statusで確認）"
        button.toolTip = issueLabel + "\n" + (button.toolTip ?? "")
        button.setAccessibilityLabel(issueLabel + "、" + (button.accessibilityLabel() ?? "TokenMeter"))
        guard issueBlinkTimer == nil else { return }
        issueDot.alphaValue = 1
        let blinkTimer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.issueDot.alphaValue = self.issueDot.alphaValue == 1 ? 0 : 1
            }
        }
        RunLoop.main.add(blinkTimer, forMode: .common)
        issueBlinkTimer = blinkTimer
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        if !store.isLinked(store.selected), let provider = ["codex", "claude"].first(where: { store.isLinked($0) }) {
            store.selected = provider
        }
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps:true)
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        store.refresh()
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pricingTimer?.invalidate()
        providerStatusTimer?.invalidate()
        issueBlinkTimer?.invalidate()
    }
}

@main struct TokenMeterMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
