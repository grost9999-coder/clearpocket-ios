import SwiftUI
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

// Only unedited, single-resource still images are eligible in this starter.
// This avoids treating a Live Photo, RAW pair or edited asset as a disposable copy.
enum PhotoScanner {
    static func digest(_ asset: PHAsset) async throws -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, resources[0].type == .photo else {
            throw ScanFailure.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let state = HashState()
            PHAssetResourceManager.default().requestData(
                for: resources[0], options: options,
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
    @Published var message = "先授權，再掃描；照片內容在手機內比對。"
    func scan() async {
        busy = true
        selected = []
        groups = []
        defer { busy = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = ScanFailure.permission.localizedDescription; return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var buckets: [String: [PHAsset]] = [:]
        var skipped = 0
        for index in 0..<result.count {
            let asset = result.object(at: index)
            message = "掃描 \(index + 1) / \(result.count)"
            do {
                let hash = try await PhotoScanner.digest(asset)
                buckets[hash, default: []].append(asset)
            } catch { skipped += 1 }
        }
        groups = buckets.keys.sorted().compactMap { key in
            guard let assets = buckets[key], assets.count > 1 else { return nil }
            return PhotoGroup(assets: assets)
        }
        message = "找到 \(groups.count) 組。略過 \(skipped) 張（雲端原檔、Live Photo、編輯照片或讀取失敗）。"
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
    var body: some View {
        List {
            Section {
                Text(model.message).font(.subheadline).foregroundStyle(.secondary)
                Button(model.busy ? "處理中…" : "開始掃描完全重複照片") {
                    Task { await model.scan() }
                }.disabled(model.busy)
                if model.busy { ProgressView() }
            } footer: { Text("第一版只比對完全相同的原始檔案。相似照片不會列入。") }
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

struct DocumentScreen: View {
    @State private var picker = false
    @State private var busy = false
    @State private var groups: [[String]] = []
    @State private var message = "選擇「檔案」中的資料夾，找出內容完全相同的文件。"
    var body: some View {
        List {
            Section {
                Text(message)
                Button("選擇資料夾") { picker = true }.disabled(busy)
                if busy { ProgressView() }
            } footer: {
                Text("目前提供重複文件清單；文件刪除尚未啟用。只掃描已下載且可讀取的文件。")
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { index, paths in
                Section("第 \(index + 1) 組") {
                    ForEach(paths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
            }
        }.navigationTitle("文件清理")
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let root):
                busy = true; groups = []; message = "正在比對文件…"
                Task {
                    let output = await Task.detached(priority: .utility) { scanDocuments(root) }.value
                    groups = output.groups; message = output.message; busy = false
                }
            }
        }
    }
}

func scanDocuments(_ root: URL) -> (groups: [[String]], message: String) {
    guard root.startAccessingSecurityScopedResource() else { return ([], "無法取得此資料夾的存取權限。") }
    defer { root.stopAccessingSecurityScopedResource() }
    var buckets: [String: [String]] = [:]
    var skipped = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true })
    else { return ([], "無法讀取此資料夾。") }
    for case let url as URL in entries {
        do {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current {
                skipped += 1; continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let key = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            buckets[key, default: []].append(relative)
        } catch { skipped += 1 }
    }
    let groups = buckets.keys.sorted().compactMap { key -> [String]? in
        guard let paths = buckets[key], paths.count > 1 else { return nil }
        return paths.sorted()
    }
    return (groups, "找到 \(groups.count) 組重複文件，略過 \(skipped) 項。")
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
                    NavigationLink { PhotoScreen() } label: { Label("照片 · 掃描與批次刪除", systemImage: "photo.on.rectangle.angled") }
                    NavigationLink { DocumentScreen() } label: { Label("文件 · 重複內容掃描", systemImage: "doc.on.doc") }
                    NavigationLink { MailScreen() } label: { Label("郵件 · 垃圾郵件清理", systemImage: "envelope") }
                }
                Section {
                    Text("開發測試版 · 尚未完成真機驗證").font(.caption).foregroundStyle(.secondary)
                    Text("不會自動清理，也不會把照片和文件內容上傳到伺服器。").font(.footnote)
                }
            }.navigationTitle("清爽口袋").tint(.teal)
        }
    }
}
