import SwiftUI
import UIKit
import GoogleSignIn
import GoogleSignInSwift

private struct GmailHeader: Decodable {
    let name: String
    let value: String
}
private struct GmailPayload: Decodable { let headers: [GmailHeader]? }
private struct GmailMessage: Decodable, Identifiable {
    let id: String
    let labelIds: [String]?
    let internalDate: String?
    let payload: GmailPayload?
    func header(_ name: String) -> String {
        payload?.headers?.first { $0.name.lowercased() == name.lowercased() }?.value ?? ""
    }
    var subject: String { header("Subject").isEmpty ? "（無標題）" : header("Subject") }
    var sender: String { header("From") }
    var date: Date { Date(timeIntervalSince1970: (Double(internalDate ?? "0") ?? 0) / 1000) }
    var eligible: Bool {
        let labels = Set(labelIds ?? [])
        return labels.contains("SPAM") && labels.isDisjoint(with: ["TRASH", "STARRED", "IMPORTANT"])
    }
}
private struct GmailPage: Decodable {
    struct Item: Decodable { let id: String }
    let messages: [Item]?
    let nextPageToken: String?
}
private struct GmailProblem: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor
private final class GmailCleanupModel: ObservableObject {
    @Published var email = ""
    @Published var messages: [GmailMessage] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var status = "連線後才會讀取 Gmail，不會自動清理。"
    @Published var onlyOld = true
    @Published var protectUnread = true
    @Published var hasMore = false
    private var nextPage: String?
    private var activeQuery: String?
    private let scope = "https://www.googleapis.com/auth/gmail.modify"
    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var configured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.contains("YOUR_") }

    private func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    func connect() async {
        guard !busy, configured, let controller = presenter() else { return }
        busy = true
        defer { busy = false }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller,
                hint: nil, additionalScopes: [scope])
            guard result.user.grantedScopes?.contains(scope) == true else {
                throw GmailProblem("尚未授權郵件整理權限，請重新連線並同意授權。")
            }
            email = result.user.profile?.email ?? "已連線 Gmail"
            resetResults()
            status = "已連線。請選擇條件，再按掃描垃圾郵件。"
        } catch { status = "連線未完成：\(error.localizedDescription)" }
    }
    func restore() async {
        guard configured, !busy, email.isEmpty else { return }
        busy = true
        defer { busy = false }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            if user.grantedScopes?.contains(scope) == true {
                email = user.profile?.email ?? "已連線 Gmail"
                status = "已恢復連線。按掃描後才會載入郵件。"
            }
        } catch { /* 沒有已儲存登入狀態時，等使用者主動登入。 */ }
    }
    func disconnect() {
        guard !busy else { return }
        GIDSignIn.sharedInstance.signOut()
        email = ""
        resetResults()
        status = "已在此裝置登出，郵件清單已清除。"
    }
    func resetResults() {
        messages = []; selected = []; nextPage = nil; hasMore = false; activeQuery = nil
    }
    private func query() -> String {
        var value = "in:spam -in:trash -is:starred -is:important"
        if onlyOld { value += " older_than:30d" }
        if protectUnread { value += " -is:unread" }
        return value
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", items: [URLQueryItem] = []) async throws -> T {
        guard let user = GIDSignIn.sharedInstance.currentUser,
              user.grantedScopes?.contains(scope) == true else {
            throw GmailProblem("請先連線 Gmail 並授權郵件整理權限。")
        }
        let refreshed = try await user.refreshTokensIfNeeded()
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        url.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(refreshed.accessToken.tokenString)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 401: throw GmailProblem("登入已失效，請登出後重新連線。")
            case 403: throw GmailProblem("Google 拒絕存取：請確認 Gmail API 已啟用、測試帳號與郵件授權已設定。")
            case 429: throw GmailProblem("請求過於頻繁，請稍後再試。")
            default: throw GmailProblem("Gmail 請求失敗（\(code)），請稍後重試。")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func metadata(_ id: String) async throws -> GmailMessage {
        try await request("messages/\(id)", items: [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From")
        ])
    }
    func scan(more: Bool = false) async {
        guard !busy, !email.isEmpty else { return }
        busy = true
        defer { busy = false }
        if !more { resetResults(); activeQuery = query() }
        guard let activeQuery else { return }
        do {
            var items = [URLQueryItem(name: "q", value: activeQuery),
                URLQueryItem(name: "includeSpamTrash", value: "true"),
                URLQueryItem(name: "maxResults", value: "50")]
            if more, let nextPage { items.append(URLQueryItem(name: "pageToken", value: nextPage)) }
            let page: GmailPage = try await request("messages", items: items)
            var loaded: [GmailMessage] = []
            for (index, item) in (page.messages ?? []).enumerated() {
                try Task.checkCancellation()
                status = "讀取郵件 \(index + 1) / \(page.messages?.count ?? 0)…"
                let message = try await metadata(item.id)
                if message.eligible && (!protectUnread || !(message.labelIds ?? []).contains("UNREAD")) {
                    loaded.append(message)
                }
            }
            let existing = Set(messages.map(\.id))
            messages += loaded.filter { !existing.contains($0.id) }
            nextPage = page.nextPageToken
            hasMore = nextPage != nil
            status = "已載入 \(messages.count) 封符合條件的垃圾郵件。\(hasMore ? "還有更多，可繼續載入。" : "本次掃描完成。")"
        } catch { status = "掃描未完成：\(error.localizedDescription)" }
    }
    func toggle(_ id: String) {
        guard !busy else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    func moveSelectedToTrash() async {
        guard !busy, !selected.isEmpty else { return }
        let targets = messages.filter { selected.contains($0.id) }.map(\.id)
        busy = true
        defer { busy = false }
        var moved = 0
        var skipped = 0
        do {
            for (index, id) in targets.enumerated() {
                status = "處理 \(index + 1) / \(targets.count)…"
                // 再讀一次最新標籤，保護已被移出垃圾郵件或加星號的信。
                let current = try await metadata(id)
                guard current.eligible && (!protectUnread || !(current.labelIds ?? []).contains("UNREAD")) else {
                    selected.remove(id); messages.removeAll { $0.id == id }; skipped += 1; continue
                }
                let _: GmailMessage = try await request("messages/\(id)/trash", method: "POST")
                moved += 1
                selected.remove(id)
                messages.removeAll { $0.id == id }
            }
            status = "已移到垃圾桶 \(moved) 封，保護或略過 \(skipped) 封。"
        } catch {
            status = "已移到垃圾桶 \(moved) 封、略過 \(skipped) 封；其餘未完成：\(error.localizedDescription)"
        }
    }
}

struct GmailCleanupScreen: View {
    @StateObject private var model = GmailCleanupModel()
    @State private var confirm = false
    var body: some View {
        List {
            Section("Gmail") {
                if model.email.isEmpty {
                    if model.configured {
                        GoogleSignInButton { Task { await model.connect() } }
                            .disabled(model.busy)
                        Text("登入時會要求郵件管理權限，用來讀取清單及把你勾選的信移到垃圾桶。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Label("Gmail 連線尚未設定", systemImage: "envelope.badge")
                        Text("完成 Google iOS 登入設定後，即可掃描和清理真實郵件。")
                            .font(.subheadline)
                    }
                } else {
                    Label(model.email, systemImage: "person.crop.circle")
                    Button("登出 Gmail") { model.disconnect() }.disabled(model.busy)
                }
            }
            Section("垃圾郵件清理") {
                Toggle("只列出超過 30 天的信", isOn: $model.onlyOld)
                Toggle("保留未讀郵件", isOn: $model.protectUnread)
                Text("只掃描 Gmail「垃圾郵件」資料夾，排除星號與重要郵件。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { Task { await model.scan() } } label: {
                    Label("掃描垃圾郵件", systemImage: "magnifyingglass")
                }.disabled(model.email.isEmpty || model.busy)
            }.disabled(model.busy)
            Section {
                if model.busy { ProgressView() }
                Text(model.status).font(.subheadline)
            }
            if !model.messages.isEmpty {
                Section("已載入 \(model.messages.count) 封 · 已選 \(model.selected.count) 封") {
                    Button(model.selected.count == model.messages.count ? "取消全選" : "全選已載入郵件") {
                        model.selected = model.selected.count == model.messages.count ? [] : Set(model.messages.map(\.id))
                    }.disabled(model.busy)
                    ForEach(model.messages) { message in
                        Button { model.toggle(message.id) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: model.selected.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(message.subject).font(.headline).foregroundStyle(.primary)
                                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                                    Text(message.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(model.busy)
                        .accessibilityLabel("\(message.subject)，\(model.selected.contains(message.id) ? "已選取" : "未選取")")
                    }
                    if model.hasMore {
                        Button("載入接下來 50 封") { Task { await model.scan(more: true) } }.disabled(model.busy)
                    }
                    Button(role: .destructive) { confirm = true } label: {
                        Label("將所選 \(model.selected.count) 封移到垃圾桶", systemImage: "trash")
                    }.disabled(model.selected.isEmpty || model.busy)
                }
            }
            Section("清理方式") {
                Text("郵件只在手機與 Google 之間傳輸，此功能只讀取標題、寄件者、日期及標籤，不下載附件。")
                Text("按確認後才會移到垃圾桶；Gmail 會依自身規則自動清除垃圾桶內的郵件。信箱容量與 iPhone 儲存空間不同。")
            }.font(.footnote)
            Section("Yahoo") {
                Text("Yahoo 連線尚未完成，目前不會讀取或清理 Yahoo 郵件。")
            }
        }
        .navigationTitle("郵件與垃圾信清理")
        .task { await model.restore() }
        .onChange(of: model.onlyOld) { _, _ in model.resetResults() }
        .onChange(of: model.protectUnread) { _, _ in model.resetResults() }
        .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
        .alert("確認清理 \(model.selected.count) 封垃圾郵件？", isPresented: $confirm) {
            Button("取消", role: .cancel) { }
            Button("移到垃圾桶", role: .destructive) { Task { await model.moveSelectedToTrash() } }
        } message: {
            Text("只處理目前勾選的郵件。清理前會再檢查垃圾郵件、星號與重要標籤。")
        }
    }
}
