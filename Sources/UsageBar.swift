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

@MainActor final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var selected = "codex"
    @Published var loading = false
    @Published var failure = ""
    @Published var notice = ""
    @Published var filter = ""
    @Published var days = 30
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    var onUpdate: (() -> Void)?
    let stateDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UsageBar")
    let collector = UsageCollector()
    let bridgeManager = BridgeManager()
    func quota(_ provider: String) -> Quota {
        (provider == "codex" ? snapshot?.codex : snapshot?.claude) ?? .empty
    }
    func isLinked(_ provider: String) -> Bool {
        let q = quota(provider)
        if let linked = q.linked { return linked }
        if provider == "claude" { return q.bridgeInstalled == true }
        return !q.windows.isEmpty || (snapshot?.sessions.contains { $0.provider == provider } == true)
    }
    var sessions: [Session] {
        let cutoff = days == 1 ? Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 : Date().timeIntervalSince1970 - Double(days) * 86400
        return (snapshot?.sessions ?? []).filter {
            $0.provider == selected && $0.updated >= cutoff &&
            (filter.isEmpty || ($0.title + $0.cwd + $0.id + $0.models.map(\.model).joined()).localizedCaseInsensitiveContains(filter))
        }
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
                if case .success(let snapshot) = result { self.snapshot = snapshot; self.failure = "" }
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
    func editPrices() {
        let target = stateDirectory.appendingPathComponent("pricing.json")
        if !FileManager.default.fileExists(atPath: target.path), let original = Bundle.main.url(forResource: "pricing", withExtension: "json") {
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: original, to: target)
        }
        NSWorkspace.shared.open(target)
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 21, weight: .semibold)).foregroundStyle(providerColor(store.selected))
                VStack(alignment: .leading, spacing: 2) {
                    Text("UsageBar").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("AIの利用状況を、ひと目で").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(store.loading).help("使用状況を更新")
                Menu {
                    Button("ログイン時に起動 " + (store.loginEnabled ? "✓" : "")) { store.toggleLogin() }
                    Button("参考単価を編集…") { store.editPrices() }
                    Button("Claude連携を" + (store.quota("claude").bridgeInstalled == true ? "解除" : "有効にする")) { store.bridge(remove: store.quota("claude").bridgeInstalled == true) }
                    Divider()
                    Button("OpenAIの公式料金表") { NSWorkspace.shared.open(URL(string:"https://developers.openai.com/api/docs/pricing")!) }
                    Button("Claudeの公式料金表") { NSWorkspace.shared.open(URL(string:"https://platform.claude.com/docs/en/about-claude/pricing")!) }
                    Divider()
                    Button("UsageBarを終了") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 24)
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)

            HStack(spacing: 8) {
                providerButton("codex", "Codex")
                providerButton("claude", "Claude")
            }.padding(.horizontal, 22).padding(.bottom, 16)
            quotaCard.padding(.horizontal, 22)
            if !store.failure.isEmpty { Text(store.failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 22).padding(.top, 8) }
            if !store.notice.isEmpty {
                HStack { Text(store.notice).font(.caption); Spacer(); Button { store.notice = "" } label: { Image(systemName:"xmark") }.buttonStyle(.plain) }.padding(10).background(.quaternary).padding(.horizontal,22).padding(.top,8)
            }
            HStack {
                Text("セッション").font(.system(size: 14, weight: .semibold))
                Text("\(store.sessions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("更新日", selection: $store.days) {
                    Text("今日更新").tag(1); Text("7日以内").tag(7); Text("30日以内").tag(30)
                }.labelsHidden().frame(width: 110).controlSize(.small)
            }.padding(.horizontal,22).padding(.top,20).padding(.bottom,10)
            HStack(spacing:8) {
                Image(systemName:"magnifyingglass").foregroundStyle(.tertiary)
                TextField("セッション名・モデル・プロジェクトで検索", text: $store.filter).textFieldStyle(.plain).font(.system(size:12))
                if !store.filter.isEmpty { Button { store.filter = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(9).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:8)).padding(.horizontal,22).padding(.bottom,10)
            HStack {
                Text("各セッションの累計").frame(maxWidth:.infinity, alignment:.leading)
                Text("INPUT").frame(width:75, alignment:.trailing)
                Text("OUTPUT").frame(width:72, alignment:.trailing)
                Text("参考 USD").frame(width:95, alignment:.trailing)
            }.font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,26).padding(.bottom,5)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if store.sessions.isEmpty {
                        VStack(spacing:10) {
                            Image(systemName:"tray").font(.system(size:28)).foregroundStyle(.tertiary)
                            Text(store.loading ? "セッションを集計しています…" : "該当するセッションがありません").font(.system(size:12)).foregroundStyle(.secondary)
                            if store.loading { Text("初回は過去のログを読み込みます").font(.caption).foregroundStyle(.tertiary) }
                        }.frame(maxWidth:.infinity).padding(.vertical,44)
                    }
                    ForEach(store.sessions) { session in SessionRow(session: session) }
                }.padding(.horizontal,16).padding(.bottom,8)
            }.frame(minHeight:160,maxHeight:.infinity)
            Divider()
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Text("表示中の累計").foregroundStyle(.secondary)
                    Spacer()
                    Text("IN " + compact(store.sessions.reduce(0) { $0 + $1.input }))
                    Text("OUT " + compact(store.sessions.reduce(0) { $0 + $1.output })).padding(.leading,8)
                    Text(money(store.sessions.reduce(0) { $0 + $1.knownCost }) + (store.sessions.contains { $0.cost == nil } ? " + 未算定" : "")).fontWeight(.semibold).padding(.leading,8)
                }.font(.system(size:11,design:.monospaced))
                Text("API標準・短コンテキストの参考額です。サブスクの追加請求額ではありません。入力はキャッシュを含み、料金には割引を反映。Fast・長文・ツール料金は対象外。").font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack {
                    Text("このMacのログ · 直近30日更新分")
                    Spacer()
                    Text("更新 " + dateText(store.snapshot?.updated ?? 0))
                }.font(.system(size:9)).foregroundStyle(.tertiary)
                if let errors = store.snapshot?.errors, !errors.isEmpty { Text(errors.joined(separator:" / ")).font(.caption2).foregroundStyle(.orange) }
            }.padding(.horizontal,22).padding(.vertical,14)
        }.frame(width:620,height:680).background(Color(nsColor:.windowBackgroundColor))
    }
    func providerButton(_ id: String, _ title: String) -> some View {
        Button { store.selected = id; store.filter = "" } label: {
            HStack {
                Image(nsImage:brandImage(id)).renderingMode(id == "codex" ? .template : .original).resizable().frame(width:18,height:18).foregroundStyle(Color.primary)
                Text(title).font(.system(size:13,weight:.semibold))
                Spacer()
                if let limit = store.quota(id).limiting { Text(String(format:"%.0f%%",limit.remaining)).font(.system(size:13,weight:.semibold,design:.rounded)).monospacedDigit() }
                else { Text("—").foregroundStyle(.secondary) }
            }.padding(.horizontal,14).padding(.vertical,12)
            .foregroundStyle(store.selected == id ? providerColor(id) : Color.secondary)
            .background(store.selected == id ? providerColor(id).opacity(0.10) : Color.primary.opacity(0.03),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(store.selected == id ? providerColor(id).opacity(0.30) : .clear,lineWidth:1))
        }.buttonStyle(.plain)
    }
    var quotaCard: some View {
        let q = store.quota(store.selected)
        return VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("残り利用枠").font(.system(size:12,weight:.semibold))
                Spacer()
                Text(q.stale && q.observed > 0 ? "最終取得値 · " + dateText(q.observed) : q.source).font(.system(size:10)).foregroundStyle(.secondary)
            }
            if q.windows.isEmpty {
                Text(store.loading && store.snapshot == nil ? "読み込み中…" : "利用枠は未取得").font(.system(size:23,weight:.semibold,design:.rounded)).foregroundStyle(.secondary)
            } else {
                ForEach(q.windows.filter { $0.bucket == "codex" || $0.bucket == "claude" }) { window in
                    VStack(spacing:5) {
                        HStack(alignment:.firstTextBaseline) {
                            Text(window.label).font(.system(size:11)).foregroundStyle(.secondary)
                            Text(window.expired ? "更新待ち" : String(format:"%.0f%%",window.remaining)).font(.system(size:24,weight:.semibold,design:.rounded)).foregroundStyle(window.expired ? Color.secondary : providerColor(store.selected)).monospacedDigit()
                            Spacer()
                            Text(window.resetsAt > 0 ? "リセット " + dateText(window.resetsAt) : "リセット時刻未取得").font(.system(size:10)).foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment:.leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule().fill(window.expired ? Color.secondary : (window.remaining < 15 ? .orange : providerColor(store.selected))).frame(width:proxy.size.width * (window.expired ? 0 : window.remaining / 100))
                            }
                        }.frame(height:5)
                    }
                }
            }
            if q.windows.contains(where: { $0.bucket != "codex" && $0.bucket != "claude" }) {
                DisclosureGroup("ほかのモデル別利用枠") {
                    ForEach(q.windows.filter { $0.bucket != "codex" && $0.bucket != "claude" }) { w in
                        HStack { Text(w.label); Spacer(); Text(w.expired ? "更新待ち" : String(format: "残り %.0f%%", w.remaining)) }.font(.system(size:10)).padding(.top,3)
                    }
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }
            Text(q.detail).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !q.error.isEmpty { Text(q.error + " · ログの最終取得値で補完").font(.system(size:10)).foregroundStyle(.orange) }
            if store.selected == "claude" && q.windows.isEmpty {
                HStack {
                    if q.bridgeInstalled != true { Button("Claude連携を有効にする") { store.bridge() }.controlSize(.small) }
                    Button("Claudeの利用状況を開く") { NSWorkspace.shared.open(URL(string:"https://claude.ai/settings/usage")!) }.controlSize(.small)
                }
            }
        }.padding(16).background(Color.primary.opacity(0.028),in:RoundedRectangle(cornerRadius:12))
    }
}

struct SessionRow: View {
    let session: Session
    @State private var expanded = false
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Button { withAnimation(.easeInOut(duration:0.15)) { expanded.toggle() } } label: {
                HStack(spacing:0) {
                    VStack(alignment:.leading,spacing:4) {
                        HStack(spacing:4) {
                            Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:8,weight:.bold)).foregroundStyle(.tertiary)
                            Text(session.title).lineLimit(1).font(.system(size:12,weight:.medium))
                        }
                        Text(dateText(session.updated) + " · " + session.models.map(\.model).joined(separator:", ")).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Text(compact(session.input)).frame(width:75,alignment:.trailing)
                    Text(compact(session.output)).frame(width:72,alignment:.trailing)
                    Text(money(session.cost)).foregroundStyle(session.cost == nil ? Color.secondary : providerColor(session.provider)).frame(width:95,alignment:.trailing)
                }.font(.system(size:11,design:.monospaced)).contentShape(Rectangle()).padding(10)
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment:.leading,spacing:8) {
                    Text(session.cwd.replacingOccurrences(of:FileManager.default.homeDirectoryForCurrentUser.path,with:"~")).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
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
                        Text("単価未設定: " + session.unknownModels.joined(separator:", ") + "。歯車メニューから単価を追加できます。").font(.system(size:10)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text(String(session.id.prefix(18)) + "…").font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary)
                        Spacer()
                        Button("IDをコピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id,forType:.string) }.buttonStyle(.plain).font(.system(size:10))
                    }
                }.padding(.horizontal,12).padding(.bottom,12).textSelection(.enabled)
            }
        }.background(Color.primary.opacity(expanded ? 0.045 : 0.02),in:RoundedRectangle(cornerRadius:9))
    }
    func detail(_ title: String, _ value: Int64) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.system(size:9)).foregroundStyle(.secondary)
            Text(value.formatted()).font(.system(size:11,weight:.medium,design:.monospaced))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    var timer: Timer?
    var previewWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let pos = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > pos + 2 {
            let input = URL(fileURLWithPath: CommandLine.arguments[pos + 1])
            let output = URL(fileURLWithPath: CommandLine.arguments[pos + 2])
            if let data = try? Data(contentsOf: input), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                store.snapshot = snapshot
                if CommandLine.arguments.contains("--claude") { store.selected = "claude" }
                let view = NSHostingView(rootView: Panel(store: store))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 620, height: 680)
                view.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
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
        if NSRunningApplication.runningApplications(withBundleIdentifier:"local.tokenmeter.TokenMeter").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).count > 0 { NSApp.terminate(nil); return }
        popover.behavior = .transient
        popover.contentSize = NSSize(width:620,height:680)
        popover.contentViewController = NSHostingController(rootView:Panel(store:store))
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "UsageBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("UsageBar")
        }
        statusItem = item
        store.onUpdate = { [weak self] in self?.updateStatus() }
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval:30,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "UsageBar"; window.contentView = NSHostingView(rootView:Panel(store:store)); window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window; NSApp.activate(ignoringOtherApps:true)
        }
    }
    func updateStatus() {
        guard let button = statusItem?.button else { return }
        let providers = ["codex", "claude"].filter { store.isLinked($0) }
        guard let first = providers.first else {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "UsageBar")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "連携中のアカウントはありません\nクリックして設定を開く"
            button.setAccessibilityLabel("UsageBar · 連携中のアカウントなし")
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
    }
}

@main struct UsageBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
