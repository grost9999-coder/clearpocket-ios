import SwiftUI
import UIKit
import Photos
import CryptoKit
import UniformTypeIdentifiers

@main
struct ClearPocketApp: App {
    var body: some Scene { WindowGroup { Dashboard() } }
}

struct PhotoGroup: Identifiable {
    let id = UUID()
    let assets: [PHAsset]
}

enum ScanFailure: LocalizedError {
    case permission, unavailable
    var errorDescription: String? {
        switch self {
        case .permission: return "請到設定允許照片存取，再重新掃描。"
        case .unavailable: return "無法讀取此項目。"
        }
    }
}

// Compare every resource, including Live Photo video and edit adjustment data.
// A failure in any resource excludes the whole asset from duplicate cleanup.
enum PhotoScanner {
    static func digest(_ asset: PHAsset, allowNetwork: Bool = true) async throws -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { throw ScanFailure.unavailable }
        var parts: [String] = []
        for resource in resources {
            let hash = try await resourceDigest(resource, allowNetwork: allowNetwork)
            parts.append("\(resource.type.rawValue):\(hash)")
        }
        return parts.sorted().joined(separator: "|")
    }
    private static func resourceDigest(_ resource: PHAssetResource, allowNetwork: Bool) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowNetwork
            let state = HashState()
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { state.append($0) },
                completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: state.finish()) }
                }
            )
        }
    }
}

final class HashState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; hasher.update(data: data) }
    func finish() -> String {
        lock.lock(); defer { lock.unlock() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class PhotoModel: ObservableObject {
    @Published var groups: [PhotoGroup] = []
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var message = "掃描所有已授權照片，含 Live Photo、RAW 與編輯照片；完整內容在手機內比對。"
    @Published var includeCloud = true
    @Published var scanning = false
    private var stopRequested = false
    func stopScan() { stopRequested = true }
    func scan() async {
        guard !busy else { return }
        busy = true; scanning = true; stopRequested = false
        selected = []
        groups = []
        defer { busy = false; scanning = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = ScanFailure.permission.localizedDescription; return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var buckets: [String: [PHAsset]] = [:]
        var skipped = 0
        var scanned = 0
        for index in 0..<result.count {
            if stopRequested { break }
            let asset = result.object(at: index)
            message = "掃描 \(index + 1) / \(result.count)"
            do {
                let hash = try await PhotoScanner.digest(asset, allowNetwork: includeCloud)
                buckets[hash, default: []].append(asset)
            } catch { skipped += 1 }
            scanned += 1
        }
        groups = buckets.keys.sorted().compactMap { key in
            guard let assets = buckets[key], assets.count > 1 else { return nil }
            return PhotoGroup(assets: assets)
        }
        message = "\(stopRequested ? "已停止" : "掃描完成")：已處理 \(scanned) / \(result.count) 張，找到 \(groups.count) 組完全重複照片。略過 \(skipped) 張（無法讀取完整資源或未允許下載雲端原檔）。"
        if status == .limited { message += " 目前只掃描已授權照片。" }
    }
    func suggest() {
        selected = Set(groups.flatMap { group in
            // Preserve all favorites, and always preserve at least the first asset.
            group.assets.dropFirst().filter { !$0.isFavorite }.map(\.localIdentifier)
        })
    }
    func toggle(_ asset: PHAsset, in group: PhotoGroup) {
        let id = asset.localIdentifier
        if selected.contains(id) { selected.remove(id); return }
        guard !asset.isFavorite,
              group.assets.filter({ !selected.contains($0.localIdentifier) }).count > 1 else { return }
        selected.insert(id)
    }
    func deleteSelected() async {
        busy = true
        defer { busy = false }
        do {
            // Re-read and re-hash every keeper and selected copy before deletion.
            var deletion: [PHAsset] = []
            for group in groups {
                let current = group.assets.compactMap { old in
                    PHAsset.fetchAssets(withLocalIdentifiers: [old.localIdentifier], options: nil).firstObject
                }
                let targets = current.filter { selected.contains($0.localIdentifier) }
                guard !targets.isEmpty else { continue }
                guard let keeper = current.first(where: { !selected.contains($0.localIdentifier) }) else {
                    throw ScanFailure.unavailable
                }
                let expected = try await PhotoScanner.digest(keeper)
                for asset in targets {
                    guard !asset.isFavorite, try await PhotoScanner.digest(asset) == expected else {
                        throw ScanFailure.unavailable
                    }
                    deletion.append(asset)
                }
            }
            guard !deletion.isEmpty else { message = "沒有可刪除項目，請重新掃描。"; return }
            let deletionIDs = Set(deletion.map(\.localIdentifier))
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(deletion as NSArray)
            }
            selected = []
            groups = groups.compactMap { group in
                let remaining = group.assets.filter { !deletionIDs.contains($0.localIdentifier) }
                return remaining.count > 1 ? PhotoGroup(assets: remaining) : nil
            }
            message = "已刪除 \(deletion.count) 張。可到「照片 → 最近刪除」查看。"
        } catch { message = "未完成清理：\(error.localizedDescription) 請重新掃描。" }
    }
}

struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.teal.opacity(0.1))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 92, height: 92).clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: 220, height: 220), contentMode: .aspectFill,
                options: options) { value, _ in
                    Task { @MainActor in image = value }
                }
        }
    }
}

struct PhotoScreen: View {
    @StateObject private var model = PhotoModel()
    @State private var confirm = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        List {
            Section {
                Toggle("包含 iCloud 雲端原檔", isOn: $model.includeCloud).disabled(model.busy)
                Text("開啟後可能下載原檔，使用網路流量並需要較長時間。").font(.footnote).foregroundStyle(.secondary)
                Button("管理照片存取權限") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.disabled(model.busy)
                Text(model.message).font(.subheadline).foregroundStyle(.secondary)
                Button(model.busy ? "處理中…" : "掃描全部已授權照片") {
                    Task { await model.scan() }
                }.disabled(model.busy)
                if model.busy { ProgressView() }
                if model.scanning {
                    Button("停止掃描（完成目前照片後停止）") { model.stopScan() }
                }
            } footer: {
                Text("要掃描整個照片圖庫，請在設定中允許「完整取用」。Live Photo、RAW 與編輯照片會比對每一份資源，全部相同才列為重複；不會將只有外觀相似的照片列入。")
            }
            if !model.groups.isEmpty {
                Button("建議勾選多餘副本") { model.suggest() }.disabled(model.busy)
            }
            ForEach(model.groups) { group in
                Section("重複照片 · \(group.assets.count) 張") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(group.assets, id: \.localIdentifier) { asset in
                                Button {
                                    model.toggle(asset, in: group)
                                } label: {
                                    VStack {
                                        Thumbnail(asset: asset)
                                        Text(asset.isFavorite ? "♥ 保護喜好項目" :
                                            (model.selected.contains(asset.localIdentifier) ? "✓ 待刪除" : "保留"))
                                            .font(.caption)
                                    }
                                }.buttonStyle(.plain).disabled(model.busy)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("照片清理")
        .safeAreaInset(edge: .bottom) {
            Button("清理已選 \(model.selected.count) 張") { confirm = true }
                .buttonStyle(.borderedProminent).tint(.teal)
                .disabled(model.selected.isEmpty || model.busy).padding()
                .frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .confirmationDialog("刪除已選的 \(model.selected.count) 張照片？", isPresented: $confirm, titleVisibility: .visible) {
            Button("確認刪除", role: .destructive) { Task { await model.deleteSelected() } }
        } message: {
            Text("每組至少保留一張。若啟用 iCloud 照片，刪除會同步至其他裝置。系統可能再次要求確認。")
        }
    }
}

struct ScannedDocument: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let bytes: Int64
    let digest: String
}
struct DocumentScanResult: Sendable {
    let files: [ScannedDocument]
    let skipped: Int
    let inaccessibleRoots: Int
}
struct DocumentScreen: View {
    @State private var picker = false
    @State private var pickFolders = true
    @State private var busy = false
    @State private var roots: [URL] = []
    @State private var files: [ScannedDocument] = []
    @State private var duplicatesOnly = false
    @State private var message = "加入「我的 iPhone」或 iCloud Drive 中可選取的資料夾，會連同所有子資料夾一起掃描。"
    private var groups: [[ScannedDocument]] {
        Dictionary(grouping: files, by: \.digest).values.filter { $0.count > 1 }
            .sorted { ($0.first?.path ?? "") < ($1.first?.path ?? "") }
    }
    var body: some View {
        List {
            Section {
                Button("加入資料夾與子資料夾") { pickFolders = true; picker = true }.disabled(busy)
                Button("加入個別文件") { pickFolders = false; picker = true }.disabled(busy)
                ForEach(roots, id: \.absoluteString) { root in
                    Label(root.lastPathComponent, systemImage: "folder")
                }
                if !roots.isEmpty {
                    Button("掃描全部已選位置") { scan() }.disabled(busy)
                    Button("清除掃描位置與結果", role: .destructive) {
                        roots = []; files = []; message = "請重新加入掃描位置。"
                    }.disabled(busy)
                }
            } header: {
                Text("掃描位置")
            } footer: {
                Text("可分次加入多個位置。iOS 僅允許讀取你選取的資料夾與文件，無法掃描其他 App 的私人檔案或整部手機的系統目錄。")
            }
            Section {
                if busy { ProgressView("正在讀取與比對所有已選位置…") }
                Text(message).font(.subheadline)
                Toggle("只顯示完全重複的文件", isOn: $duplicatesOnly)
            } footer: {
                Text("只讀取已下載的檔案；雲端未下載、無權限或讀取失敗項目會略過。文件內容在手機內比對；文件刪除尚未啟用。")
            }
            if duplicatesOnly {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    Section("重複文件第 \(index + 1) 組 · \(group.count) 份") {
                        ForEach(group) { documentRow($0) }
                    }
                }
            } else {
                Section("所有可讀文件 · \(files.count) 份") {
                    ForEach(files) { documentRow($0) }
                }
            }
        }
        .navigationTitle("文件全面掃描")
        .fileImporter(isPresented: $picker,
                      allowedContentTypes: pickFolders ? [.folder] : [.data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let error): message = "未加入位置：\(error.localizedDescription)"
            case .success(let urls):
                for url in urls where !roots.contains(url) { roots.append(url) }
                files = []
                message = "已加入 \(roots.count) 個位置。請按「掃描全部已選位置」。"
            }
        }
    }
    private func documentRow(_ file: ScannedDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.name).font(.headline)
            Text(file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func scan() {
        guard !busy else { return }
        busy = true; files = []; message = "正在掃描全部已選位置…"
        let selectedRoots = roots
        Task {
            let result = await Task.detached(priority: .utility) { scanDocuments(selectedRoots) }.value
            files = result.files
            message = "已掃描 \(files.count) 份文件，找到 \(groups.count) 組完全重複文件。略過 \(result.skipped) 項，\(result.inaccessibleRoots) 個位置無法存取。"
            busy = false
        }
    }
}

func scanDocuments(_ roots: [URL]) -> DocumentScanResult {
    var files: [ScannedDocument] = []
    var visited = Set<String>()
    var skipped = 0
    var inaccessibleRoots = 0
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]
    func readFile(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !visited.contains(path) else { return }
        visited.insert(path)
        do {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current {
                skipped += 1; return
            }
            // Stream the file rather than allocating its full size in memory.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            var bytes: Int64 = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk); bytes += Int64(chunk.count)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            files.append(ScannedDocument(path: path, name: url.lastPathComponent, bytes: bytes, digest: digest))
        } catch { skipped += 1 }
    }
    for root in roots {
        guard root.startAccessingSecurityScopedResource() else { inaccessibleRoots += 1; continue }
        defer { root.stopAccessingSecurityScopedResource() }
        do {
            let values = try root.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { skipped += 1; continue }
            if values.isDirectory == true {
                // Do not follow symlinks or enter document packages as folders.
                guard let entries = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in skipped += 1; return true }) else {
                    inaccessibleRoots += 1; continue
                }
                for case let url as URL in entries { readFile(url) }
            } else { readFile(root) }
        } catch { inaccessibleRoots += 1 }
    }
    return DocumentScanResult(files: files.sorted { $0.path < $1.path },
                              skipped: skipped, inaccessibleRoots: inaccessibleRoots)
}

struct MailScreen: View {
    var body: some View { GmailCleanupScreen() }
}

struct Dashboard: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 42)).foregroundStyle(.teal)
                        Text("讓手機，輕一點。").font(.largeTitle.bold())
                        Text("先看清楚，再安心清理。").foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                }
                Section("清理工具") {
                    NavigationLink { PhotoScreen() } label: { Label("照片 · 全部已授權照片掃描", systemImage: "photo.on.rectangle.angled") }
                    NavigationLink { DocumentScreen() } label: { Label("文件 · 全部已選位置掃描", systemImage: "doc.on.doc") }
                    NavigationLink { MailScreen() } label: { Label("郵件 · 全部郵件整理", systemImage: "envelope") }
                }
                Section {
                    Text("開發測試版 · 尚未完成真機驗證").font(.caption).foregroundStyle(.secondary)
                    Text("不會自動清理，也不會把照片和文件內容上傳到伺服器。").font(.footnote)
                }
            }.navigationTitle("清爽口袋").tint(.teal)
        }
    }
}

