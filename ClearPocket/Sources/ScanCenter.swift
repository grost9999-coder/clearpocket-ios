import SwiftUI
import UIKit
import Photos
import Combine

@MainActor
final class DocumentModel: ObservableObject {
    @Published var busy = false
    @Published var roots: [URL] = []
    @Published var files: [ScannedDocument] = []
    @Published var canResume = false
    @Published var message = "請先加入要掃描的資料夾或文件。"
    private(set) var cancellation: ScanCancellation?
    var groups: [[ScannedDocument]] {
        Dictionary(grouping: files, by: \.digest).values.filter { $0.count > 1 }
            .sorted { ($0.first?.path ?? "") < ($1.first?.path ?? "") }
    }
    init() {
        if let bookmarks = ScanCheckpoint.load("document-roots", as: [Data].self) {
            roots = bookmarks.compactMap { data in
                var stale = false
                return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
        }
        if let saved = ScanCheckpoint.load("documents", as: DocumentScanCheckpoint.self),
           saved.roots == roots.map(\.absoluteString) {
            files = saved.files; canResume = saved.pending
            message = "已恢復 \(files.count) 份文件，\(canResume ? "可接續掃描。" : "上次已完成。")"
        }
    }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        for url in urls where !roots.contains(url) { roots.append(url) }
        files = []; canResume = false; ScanCheckpoint.clear("documents")
        let bookmarks = roots.compactMap { url -> Data? in
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            return try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        ScanCheckpoint.save(bookmarks, name: "document-roots")
        message = "已加入 \(roots.count) 個位置，可開始掃描。"
    }
    func clear() {
        guard !busy else { return }
        roots = []; files = []; canResume = false
        ScanCheckpoint.clear("documents"); ScanCheckpoint.clear("document-roots")
        message = "請重新加入掃描位置。"
    }
    func stop() { cancellation?.cancel() }
    func scan(resume: Bool = false) {
        guard !busy else { return }
        guard !roots.isEmpty else { message = "請先選擇文件掃描位置。"; return }
        let lease = BackgroundScanLease(name: "Document scan")
        let token = lease.cancellation
        cancellation = token
        busy = true; files = []; message = "正在讀取與比對文件…"
        let selectedRoots = roots
        Task {
            defer { lease.end(); cancellation = nil; busy = false }
            let result = await Task.detached(priority: .utility) {
                scanDocuments(selectedRoots, resume: resume, cancellation: token)
            }.value
            files = result.files; canResume = result.paused
            message = "\(canResume ? "已暫停。" : "掃描完成。")共 \(files.count) 份，\(groups.count) 組重複；略過 \(result.skipped) 項，\(result.inaccessibleRoots) 個位置無法存取。"
        }
    }
}

// One app-wide owner keeps jobs alive when navigating between feature pages.
@MainActor
final class ScanCenter: ObservableObject {
    static let shared = ScanCenter()
    let photos = PhotoModel(mediaType: .image)
    let videos = PhotoModel(mediaType: .video)
    let documents = DocumentModel()
    let mail = GmailCleanupModel()
    @Published var launching = false
    @Published var keepScreenOn = false { didSet { updateIdleTimer() } }
    @Published var notice = "照片、影片、文件與郵件可同時掃描，切換功能頁不會建立另一份工作。"
    private var subscriptions = Set<AnyCancellable>()
    private var previousIdleSetting: Bool?
    var anyBusy: Bool { photos.busy || videos.busy || documents.busy || mail.busy || launching }
    private init() {
        for publisher in [photos.objectWillChange, videos.objectWillChange,
                          documents.objectWillChange, mail.objectWillChange] {
            publisher.sink { [weak self] _ in
                Task { @MainActor in
                    self?.objectWillChange.send()
                    self?.updateIdleTimer()
                }
            }.store(in: &subscriptions)
        }
    }
    private func updateIdleTimer() {
        if keepScreenOn && anyBusy {
            if previousIdleSetting == nil { previousIdleSetting = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            self.previousIdleSetting = nil
        }
    }
    func startAll() {
        guard !anyBusy else { return }
        launching = true
        Task {
            // Ask for photo-library permission once before launching both media jobs.
            let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await mail.restore()
            if permission == .authorized || permission == .limited {
                Task { await photos.scan(resume: photos.canResume) }
                Task { await videos.scan(resume: videos.canResume) }
            }
            documents.scan(resume: documents.canResume)
            if !mail.email.isEmpty { Task { await mail.scan(more: mail.hasMore) } }
            else { mail.status = "請先到郵件頁登入 Gmail，再開始郵件掃描。" }
            launching = false
            notice = "已啟動可執行的掃描。文件需先選位置，Gmail 需先登入；相簿需授權。長時間掃描建議留在 App 並開啟保持螢幕亮起。"
            updateIdleTimer()
        }
    }
    func stopAll() {
        photos.stopScan(); videos.stopScan(); documents.stop(); mail.stopScan()
        notice = "正在保存進度並停止各項掃描。"
    }
}

struct ScanControlScreen: View {
    @ObservedObject private var center = ScanCenter.shared
    var body: some View {
        List {
            Section {
                Button("同時開始／接續四項掃描") { center.startAll() }.disabled(center.anyBusy)
                Button("停止全部掃描") { center.stopAll() }.disabled(!center.anyBusy || center.launching)
                Toggle("掃描時保持螢幕亮起", isOn: $center.keepScreenOn)
                Text(center.notice).font(.footnote)
            } header: { Text("統一掃描控制台") } footer: {
                Text("保持螢幕亮起僅在 App 前景有效，會增加耗電。切到其他 App 或鎖屏後，iOS 仍可能暫停工作；舊版 iOS 不提供無限背景掃描。強制關閉 App 會停止執行。")
            }
            Section("四項掃描進度") {
                NavigationLink { PhotoScreen(model: center.photos) } label: {
                    row("照片", message: center.photos.message, busy: center.photos.busy)
                }
                NavigationLink { PhotoScreen(model: center.videos) } label: {
                    row("影片", message: center.videos.message, busy: center.videos.busy)
                }
                NavigationLink { DocumentScreen(model: center.documents) } label: {
                    row("文件", message: center.documents.message, busy: center.documents.busy)
                }
                NavigationLink { GmailCleanupScreen(model: center.mail) } label: {
                    row("郵件", message: center.mail.status, busy: center.mail.busy)
                }
            }
        }.navigationTitle("同時掃描")
    }
    private func row(_ title: String, message: String, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.headline); if busy { ProgressView() } }
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
