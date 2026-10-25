# 清爽口袋｜iPhone 清理 App 開發起始版

需求：整理重複照片、文件、Gmail 與 Yahoo 郵件，確認後批次清理。

**這是 SwiftUI 原始碼與開發設計，並非可直接安裝的 IPA。**
目前環境沒有 Xcode 或 iOS SDK；未編譯、未簽名、未執行真機測試。原始碼及壓縮檔檢查不能代替功能驗收。

## 實作範圍

| 功能 | 此版狀態 |
|---|---|
| 照片授權與限制存取提示 | 已寫入原始碼，待真機測試 |
| 完全重複照片 | 串流 SHA-256 比對；只納入單一原始圖片資源 |
| 預覽與勾選 | 縮圖、每組至少保留一張、喜好照片不可勾選 |
| 批次刪除照片 | 刪除前重新讀取及比對，確認後呼叫 PhotoKit；待測試 |
| Live Photo、RAW 配對、編輯照片、僅雲端原檔 | 略過並計數 |
| 相似照片 | 尚未實作 |
| 重複文件 | 掃描選定資料夾，顯示相對路徑，串流比對內容 |
| 文件刪除 | 尚未實作，介面明確標示 |
| Gmail / Yahoo | 僅設定狀態及設計規則，尚未連接或讀取郵件 |

照片和文件比對不需要 AI API，不上傳內容。沒有虛構掃描數量或容量。
第三方文件供應商仍可能因讀取而下載檔案，不能保證所有供應商都離線工作。

## 在 Mac 建立測試 App

1. 安裝 Xcode 及 XcodeGen。
2. 在本資料夾執行 xcodegen generate，產生 ClearPocket.xcodeproj。
3. 用 Xcode 開啟，在 Signing & Capabilities 選擇自己的 Team，設定唯一 Bundle Identifier。
4. 連接測試 iPhone，選擇裝置執行；依提示完成開發者模式及信任設定。
5. 先用測試相簿驗證，未驗收前不在重要照片上操作。

替代方式：在 Xcode 新增 iOS App（SwiftUI、Swift），刪除範本 App / ContentView，加入 Sources 檔案，
設定 iOS 17 以上及 NSPhotoLibraryUsageDescription 權限說明。此方式不需要 XcodeGen。

## 畫面與流程

首頁：讓手機，輕一點。照片、文件、郵件三個入口。
照片：掃描 → 群組 → 建議勾選 → 自行調整 → 清理已選 → 確認 → 系統執行。
文件：選資料夾 → 比對 → 依群組列出路徑。
郵件：分開顯示 Gmail / Yahoo 狀態；未接通時沒有可用清理按鈕。

正式版需加入全螢幕比較、暫停／取消掃描、進度保存、動態字體及 VoiceOver 驗收。
預估可清理容量與實際釋放容量分開；進入最近刪除不保證立即釋放手機空間。
iCloud 照片刪除會同步到其他裝置，確認畫面已有提示。

## Gmail 整合（待開發）

- 設定 Google Cloud、iOS OAuth 用戶端、同意畫面及必要審查。
- 使用官方登入流程，不收集密碼；token 存 Keychain，不寫入程式碼或日誌。
- 啟用清理時才要求必要權限；gmail.modify 可將郵件移到垃圾桶。
- 分頁取得郵件，再取必要內容；未載完不得顯示「沒有重複」。
- 同標題不構成重複；比對寄件者、收件者、內文及附件，Message-ID 僅作輔助。
- 排除草稿／垃圾桶，星號及重要信預設保護；促銷信、大附件獨立分類。
- 預覽後逐封移到垃圾桶，回報成功／失敗；重試只處理失敗項目。
- 不永久刪除、不自動清空垃圾桶。

## Yahoo 整合（待開發）

官方入口說明提供 IMAP 搭配 OAuth2，受申請及政策限制。
先確認開發者郵件存取資格、OAuth 設定及審核要求，再選擇維護中的 iOS IMAP 實作。
尚未完成 Yahoo 申請，不能承諾此版可連接；Gmail token 也不能用於 Yahoo。
依伺服器能力與垃圾桶資料夾執行移動，不使用無差別 EXPUNGE。
分帳號清理；跨信箱相同內容不預設為可刪副本。

## 文件刪除後續（待開發）

重新比對保留檔及副本、顯示完整路徑、排除符號連結與套件內部檔案。
File Provider 的刪除及復原能力不同，不能保證都會進入最近刪除。
驗證協調存取、外部修改、權限失效、雲端同步及失敗復原後才啟用刪除。
若供應商沒有可復原操作，明確提示並提供備份選項。

## 真機驗收

- 拒絕／有限／完整相簿權限，及從設定撤回權限。
- 0 張／1 張／2 張相同照片；同檔名不同內容；編輯副本、Live Photo、RAW。
- 每組至少保留一張、保護喜好項目、取消系統確認後未刪除。
- 掃描後檔案修改／移除／改成喜好，清理停止或要求重新掃描。
- 僅雲端原檔略過；大量照片、記憶體、鎖屏、背景中斷。
- 文件同內容不同名／同名不同內容／空檔案／子目錄／權限與讀取錯誤。
- 信箱接通後驗證 token 過期、分頁、限流、部分失敗及垃圾桶移動。

## 官方參考

- https://developer.apple.com/documentation/photokit
- https://developer.apple.com/documentation/uikit/providing-access-to-directories
- https://developers.google.com/workspace/gmail/api/auth/scopes
- https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/trash
- https://senders.yahooinc.com/developer/developer-access/

查核日期：2026-10-25。帳號申請及部署時需確認當時要求。
