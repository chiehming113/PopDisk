# 架構總覽

## App 型態
- SwiftUI `App`，兩個 scene：
  - `MenuBarExtra(.window)`：主介面，點選單列圖示彈出的面板
  - `Settings`：設定視窗（⌘,）
- `LSUIElement = YES`，沒有 Dock 圖示與主選單。因為 App 不是前景 App，開設定視窗前要先 `NSApp.activate()`，視窗才會跳到最前面。
- 不開 App Sandbox，只在 GitHub 發佈、不上 Mac App Store。曾在 0.1.0 開發期間開啟沙盒評估上架（2026-10-26），實測沙盒內看不到也不能結束其他程式（libproc、`kill`）、不能直接開啟卷宗（`NSWorkspace.open`）、不能裝載內建讀卡機的 SD 卡（`kDAReturnNotPrivileged`），網路碟也會帶 `quarantine` 旗標；這些是核心功能，所以決定不開沙盒。

## 分層

```
 Views (SwiftUI)
   │  讀取狀態 / 呼叫動作
   ▼
 Stores (@Observable @MainActor)
   │  VolumeStore：[ExternalDrive]、eject / mount / ejectAll
   │  NetworkStore：[NetworkVolume]、常用清單、connect / eject、重連、網路連線速度
   │  ThroughputStore：定時取樣傳輸速度（依選單開關與設定）
   │  AppSettings：使用者設定（UserDefaults）
   │  PreferencesStore：每顆硬碟的暱稱、圖示、排序、釘選、隱藏
   │  AutomationController：通知、空間警示、睡眠前退出、全域快捷鍵（非 Observable）
   │  UpdateStore：Sparkle 的 App 內更新、背景找到新版時的選單提示
   ▼
 Services（包裝系統 API，C callback → closure / async）
   DiskArbitrationService   外接碟出現/消失/變更、mount、unmount、eject
   NetworkMountService      NetFS 掛載、unmountVolume、協定辨識
   LinkSpeedService         IOKit 介面速度、網卡速率、延遲
   ThroughputService        IOBlockStorageDriver 統計、網卡位元組計數
   QuickActions             在 Finder / 終端機開啟、在 Finder 中顯示、拷貝路徑、暱稱輸入
   BusyProcessService       libproc 找出佔用卷宗的程式
   NetworkReconnectService  NWPathMonitor + 喚醒事件 → 重新掛載
   PowerEventService        睡眠/喚醒通知（網路重連用）
   SystemSleepService       IOKit 電源通知，可延後睡眠直到退出完成
   KeychainService          網路硬碟密碼
   LoginItemService         SMAppService
   NotificationService      UserNotifications
   HotKeyService            Carbon RegisterEventHotKey
```

### 資料流
1. Service 收到系統事件（例如 DiskArbitration 的 disk appeared callback，在 DA 的 dispatch queue 上）。
2. Service 把事件轉成 Swift 值型別，切回 `@MainActor` 交給 `VolumeStore`。
3. `VolumeStore` 更新 `[ExternalDrive]`，SwiftUI 透過 Observation 自動重繪。
4. 使用者動作（退出、裝載）由 View 呼叫 Store，Store 呼叫 Service 的 async 方法並更新每列的 `ejectState`。

### Store 與 Service 的關係
- `PopDiskApp.init` 建立一個 `DiskArbitrationService`，同時交給 `VolumeStore` 與 `NetworkStore`（網路卷宗的卸載也走 DiskArbitration，共用 busy 判斷）
- 所有 Store 都在 `PopDiskApp.init` 建立（`@State`），不必等選單打開就開始監聽事件。`AutomationController` 也在這裡建立並 `start()`，只被 App 持有，不放進 environment
- `AppSettings.onChange` 接到 `ThroughputStore.reschedule()`：選單列顯示方式、取樣間隔改變時重新判斷要不要取樣
- 各 View 從 environment 讀需要的 Store：
  - `MenuContentView`（面板）：`VolumeStore`、`NetworkStore`、`ThroughputStore`、`PreferencesStore`、`UpdateStore`
  - `MenuBarLabel`（選單列圖示）：`AppSettings`、`VolumeStore`、`NetworkStore`、`ThroughputStore`、`PreferencesStore`
  - `SettingsView`：`AppSettings`、`NetworkStore`、`PreferencesStore`、`UpdateStore`

### 主要模型
- `ExternalDrive` / `Volume`：實體外接裝置與其上的卷宗（BSD 名稱、掛載路徑、檔案系統、容量）
- `NetworkVolume`：已掛載的網路卷宗（協定、伺服器位址、容量）
- `EjectState`：idle / ejecting / busy(佔用程式) / failed(訊息)，外接與網路共用
- `BusyProcess`：佔用卷宗的程式與所屬 App
- `VolumePreference`：個人化設定（暱稱、圖示、釘選、隱藏、最後看到的名稱），`PreferencesStore` 以 key → `VolumePreference` 存成 JSON（UserDefaults `volumePreferences`），自訂順序另存 `volumeOrder`。key 為 `preferenceKey`：外接碟用整碟分割表中最小的分割區 GUID（`drive:<GUID>`，換插孔、重開機都不變）。分割區在磁碟讀取時就全部出現，不像卷宗是一個一個掛上，key 才不會在出現過程中變動；MBR 或沒有分割表的裝置退回最小的卷宗 UUID，再沒有就用 BSD 名稱。舊版以卷宗 UUID 為 key，`PreferencesStore.migrate` 會把有改過的設定搬到新 key，並清掉只有名稱的空白紀錄。選單過濾（`visible()`）不以 key 去重，相同 key 的硬碟（例如複製的映像檔）都會顯示，網路碟用分享位址（`share:<協定>://<主機>/<路徑>`）
- `LinkInfo`：連線介面（USB / Thunderbolt / PCIe / Wi‑Fi / 乙太網路）、協商速度、延遲、速度受限原因
- `NetworkFavorite`：名稱、URL、使用者名稱、啟動時自動連線（密碼存 Keychain，不存在 UserDefaults）
- `ShareKey`：比對「同一個分享」用（協定類別 + 主機 + 路徑，忽略使用者名稱與大小寫）；`BonjourService`：拆解 `MyNAS._smb._tcp.local` 這種服務名稱
- `TransferRate`：每秒讀寫（或下載／上傳）位元組數，含「傳輸中」與「顯示 —」的門檻
- `HotKey`：全域快捷鍵的鍵碼與 Carbon 修飾鍵，JSON 存在 UserDefaults
- `AppSettings`：`@Observable` 類別，每個屬性在 `didSet` 時寫回 UserDefaults（不用 `@AppStorage`，因為 Store 與 `AutomationController` 也要讀、要收到變更通知）；另有不儲存的狀態 `hotKeyConflicts`、`recordingHotKey`

## App 內更新（Sparkle）
- **為什麼用第三方套件**：自己寫更新要處理 EdDSA 簽章驗證、下載、解壓、替換正在執行的 App 再重新啟動，任何一步出錯都可能讓使用者的 App 壞掉；Sparkle 是 macOS 上的標準做法（MIT 授權），所以這是唯一的例外。以 Swift Package 加入，版本固定在 `Package.resolved`
- **兩個 repo**：開發在私有 repo 進行；公開 repo `chiehming113/PopDisk` 放原始碼、`appcast.xml`、Releases 與 Issues。每次發佈時，把這一版的原始碼（不含維護者用的 `internal/` 與 `CLAUDE.md`）同步成公開 repo 的一個「PopDisk <版本>」commit，Release 的 tag 就打在這個 commit 上。私有 repo 的開發紀錄不會公開
  - feed：`https://raw.githubusercontent.com/chiehming113/PopDisk/main/appcast.xml`（`Config/Info.plist` 的 `SUFeedURL`）
  - 下載：`https://github.com/chiehming113/PopDisk/releases/download/v<版本>/PopDisk-<版本>.zip`
  - 兩次發佈之間只會更新文件（README、CHANGELOG 等）與 appcast，原始碼只在發佈時更新
- **簽章**：每個 zip 用 EdDSA 私鑰簽章（`sign_update`），App 用 `SUPublicEDKey` 驗證；私鑰只在維護者手上，不在 repo 裡。另外 Sparkle 也會確認新版的程式碼簽章和舊版是同一個 Developer ID
- **授權**：PopDisk 採用 MIT 授權（0.1.0 之後；0.1.0 附帶的是不開源的使用條款）。和 Sparkle 相同，對使用與修改的限制最少
- **版本比對**：Sparkle 比的是 `CFBundleVersion`（`CURRENT_PROJECT_VERSION`），每次發佈都要比上一版大；`release.sh` 會檢查
- **選單列 App 的提醒方式**：`SUEnableAutomaticChecks = YES`，預設每天檢查、不在第二次啟動時詢問。`LSUIElement` 的 App 不在前景，Sparkle 的更新視窗容易被蓋住，所以實作「溫和提醒」（`supportsGentleScheduledUpdateReminders`）：剛啟動或閒置一段時間後（`immediateFocus`）照常跳出視窗；其他時候改成選單底部的「安裝…」與一則通知，使用者處理過後（`DidReceiveUserAttention`／`WillFinishUpdateSession`）收起。使用者主動檢查前先 `NSApp.activate()`
- **安裝前一定詢問**：不開 `SUAutomaticallyUpdate`，找到新版只提醒，使用者按「安裝更新」才下載
- **更新說明**：appcast 的 `<description sparkle:format="markdown">` 直接放 CHANGELOG 該版本的段落
- **紀錄**：`UpdateStore` 用 `Logger`（category `update`）記下找到新版、是否立即顯示、交給誰顯示、工作階段結束等事件，查不出提醒為什麼沒出現時用
- **Debug 測試用參數**：`-updateFeedURL <網址>`（`feedURLString(for:)`，只在 Debug 有效）改用本機 feed；`-checkForUpdatesAtLaunch YES` 啟動 2 秒後主動檢查（macOS 27 的選單列面板無法用 UI 腳本點開，這樣才能自動化測試）

## 關於頁
- 「設定 → 關於」：版本與「檢查更新…」、版權（`NSHumanReadableCopyright`）、網站／新版說明／GitHub 上的授權條款／隱私／回報問題連結（都指向公開 repo，集中在 `AppLinks`；授權條款與隱私依 App 實際使用的介面語言開英文或繁中版，繁中授權條款是參考譯文）、「拷貝系統資訊」（`SystemInfo`：版本、macOS、`hw.model`、`machdep.cpu.brand_string`、語言，不含硬碟名稱與伺服器位址）、PopDisk 自己的授權全文（`License.txt`，和 repo 根目錄的 `LICENSE` 相同，`preflight.sh` 會檢查；繁中介面先顯示 `License.zh-Hant.txt` 的參考譯文，再接英文正式版本，譯文和 `LICENSE.zh-Hant.md` 兩條 `---` 之間的段落相同，`preflight.sh` 也會檢查）、開源軟體致謝（`Acknowledgements.txt`，Sparkle 的 LICENSE 全文，MIT 要求散佈時附上）

## 選單互動
- **個人化**：`PreferencesStore.visible(_:key:name:)` 過濾隱藏項目並排序（釘選 → 自訂順序 → 名稱）。看過的硬碟由 `MenuBarLabel` 的 `onChange(initial: true)` 記錄（選單列一直存在，選單沒打開過也會記錄），所以會出現在「設定 → 硬碟」
- **快速動作**：`RowActions` 同時供 ⋯ 選單與右鍵選單使用；點卷宗本身在 Finder 開啟；⋯ 選單另有「在 Finder 中顯示」（`activateFileViewerSelecting`）
- **資訊面板**：每列可展開 `InfoGrid`，值可選取拷貝。外接碟：裝置（廠商＋型號）、BSD 名稱、序號、連接方式、讀卡機（SD 卡）、每個卷宗的名稱、檔案系統、精確容量、位置、UUID；網路碟：協定、完整伺服器網址、位置、容量、連接方式、網卡
- **面板大小**：寬 300 pt，整體高度上限 600 pt（含底部按鈕）。硬碟清單放在 `ScrollView` 裡，`ScrollView` 沒有理想高度，所以用 `onGeometryChange` 量出清單與底部的實際高度，給 `frame(height: min(清單, 600 − 底部))`（底部包含更新提示與分隔線）：內容少時面板跟著縮短，超過才捲動。展開／收合資訊的動畫中外框高度會比內容晚一拍，短暫超出就會跳出捲軸再淡出，所以內容沒超過上限時用 `scrollIndicators(.never)` 隱藏捲軸。底部按鈕固定不捲動；↑↓ 選取時用 `ScrollViewReader.scrollTo` 把選取的列捲進畫面（每列以 `RowID` 當 `.id`）。Debug 截圖模式在螢幕外畫面板時，要先等一輪讓高度量完再算 `fittingSize`
- **字級**：硬碟名稱 `body`（13 pt）；容量、連線方式、傳輸速度、警告與錯誤用 `callout`（12 pt），讓使用者最常看的資訊不是最小的字（中文在 10 pt 筆畫太密）；區段標題、資訊面板、佔用程式列表、底部提示用 `caption`／`caption2`（10 pt）。容量那行用 `ViewThatFits` 在放不下時省略檔案系統
- **鍵盤**：根 VStack `.focusable()` + `onKeyPress` 處理 ↑↓ ↩ esc（esc 只在有選取時取消選取，否則交給系統關閉面板）；⌘E / ⇧⌘E / ⌘I 放在背景透明按鈕的 `keyboardShortcut` 上（選單面板取得焦點時即可觸發）；⌘, 與 ⌘Q 是底部「設定…」「結束 PopDisk」按鈕的快捷鍵
- **空白狀態**：沒有網路碟也沒有常用網路硬碟時顯示「新增網路硬碟…」連結；有隱藏的硬碟時顯示「已隱藏 N 顆硬碟，到設定中查看…」，兩者都打開設定視窗
- **暱稱輸入**：選單列面板內 SwiftUI alert / sheet 不穩定，用 `NSAlert` + `accessoryView` 文字欄位

## 設定視窗
`SettingsView` 是 `TabView`（寬 520 pt），五個分頁：
| 分頁 | View | 內容 |
|---|---|---|
| 一般 | `GeneralSettingsView` | 登入時開啟（`.requiresApproval` 時提示並可打開系統設定）、睡眠前退出、選單列顯示（數量／箭頭／速度）、自動檢查更新、傳輸速度取樣間隔 |
| 硬碟 | `DrivesSettingsView` | 看過的硬碟清單：暱稱、圖示、≡ 拖曳排序、釘選、隱藏、清除設定（`forget`）。暱稱欄會吃掉拖曳，所以另給拖曳把手 |
| 網路硬碟 | `FavoritesSettingsView` | 常用網路硬碟的新增／編輯（`.sheet`，設定視窗是一般視窗，可以用 sheet）／刪除／拖曳排序、自動重新連線 |
| 通知 | `NotificationSettingsView` | 各類通知開關、空間門檻、通知被關掉時的提示、兩個全域快捷鍵（`HotKeyRecorder`） |
| 關於 | `AboutSettingsView` | 見上方「關於頁」 |

## 在地化
- `Localizable.xcstrings`（String Catalog），開發語言 en，另有 zh-Hant；檢查是否齊全的指令見 [development.md](development.md)
- zh-Hant 用詞統一：drive／disk 都稱「硬碟」（資訊面板的 BSD 名稱欄除外）、Saved Servers（原 Favorites）稱「常用網路硬碟」、select 稱「選取」、佔用硬碟的對象稱「程式」或「App」（不用「程序」）；mount／volume 沿用 Apple 的「裝載」「卷宗」
- 選單裡的容量最多一位小數（`Int64.compactByteCount`，1000 進位，和 Finder 一致）；資訊面板保留 `.byteCount(style: .file)` 的精確值。Bonjour 服務名稱在選單只顯示名稱部分（`NetworkVolume.displayHost`），資訊面板仍顯示完整網址
- 程式中一律用英文 key，`SWIFT_EMIT_LOC_STRINGS = YES` 讓 Xcode 建置時自動抽出新字串

## 開發進度

| # | 里程碑 | 狀態 |
|---|---|---|
| 1 | 專案骨架、文件、資源資料夾 | ✅ |
| 2 | 外接硬碟列表、退出／裝載、退出進度、容量條 | ✅ |
| 3 | 佔用 App 偵測、強制退出 | ✅ |
| 4 | 網路硬碟：列表、退出、常用網路硬碟＋Keychain、登入自動掛載、斷線重連 | ✅ |
| 5 | 介面協商速度、瓶頸提醒 | ✅ |
| 6 | 即時傳輸速度、選單列圖示狀態 | ✅ |
| 7 | 暱稱／圖示／排序、進階資訊面板、快速動作、鍵盤操作 | ✅ |
| 8 | 開機啟動、通知、空間警示、全域快捷鍵、休眠前退出、翻譯補齊 | ✅ |
| 9 | App 圖示、截圖、文件總檢查 | ✅ |
