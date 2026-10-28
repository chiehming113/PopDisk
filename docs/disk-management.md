# 外接硬碟管理

實作：`PopDisk/Services/DiskArbitrationService.swift`、`PopDisk/Stores/VolumeStore.swift`

## 偵測
- `DASessionCreate` + `DASessionSetDispatchQueue(session, .main)`：所有 callback 都在主執行緒，Service 標成 `@MainActor`，callback 內用 `MainActor.assumeIsolated` 進入
- 註冊 `DiskAppeared` / `DiskDescriptionChanged`（掛載、卸載、改名都會觸發）/ `DiskDisappeared`
- Service 只保存「目前可見的卷宗」`[BSD 名稱: DADisk]`，由 `VolumeStore.reload()` 重建清單
  - 與清單無關的事件（內接碟、整碟、隱藏的 APFS 卷宗）直接忽略
  - 接上一顆硬碟會連續收到數十個事件：`volumeDisks` 立即更新，`onChange` 則合併成一次，最多延後 0.2 秒
  - `VolumeStore` 的裝載、退出完成後直接 `reload()`，不等合併後的通知，畫面才不會閃
- 容量在 `drives()` 時從掛載路徑的 `volumeTotalCapacity` / `volumeAvailableCapacity` 讀取；未裝載的卷宗只有 DA 的 `MediaSize`（顯示「未裝載 · 大小」）。選單打開時會 `reload()` 一次，讓剩餘空間保持最新

## 過濾規則（決定哪些卷宗要顯示）
1. 有檔案系統（`VolumeKind` 存在）、不是網路卷宗、`VolumeMountable` 不為 false
2. **實體整碟**的 `DeviceInternal` 不為 true，或媒體可移除／可退出（`MediaRemovable` / `MediaEjectable`）
   - APFS 合成碟本身沒有 `DeviceInternal`，必須看背後的實體碟
   - 磁碟映像檔完全沒有這個 key（是 nil，不是 false），所以條件寫成「不為 true」
   - Mac 內建讀卡機的 SD 卡是內部裝置，但媒體可移除，比照 Finder 顯示；內建 SSD 兩者都是 false
3. APFS 系統輔助卷宗（IOMedia 的 `Role` 含 Preboot / Recovery / VM / Update 等）不顯示
4. 以 `MNT_DONTBROWSE`（nobrowse）掛載的卷宗不顯示，比照 Finder。例如 Xcode 的模擬器 runtime 映像，退掉會讓模擬器壞掉

## 實體裝置分組
- 退出是以「整顆實體裝置」為單位，所以清單依實體整碟分組（`ExternalDrive`），一個裝置可能有多個卷宗
- APFS 卷宗（例如 `disk7s1`）的 whole disk 是合成碟 `disk7`，要沿 IORegistry 往上找：
  `IOMedia disk7` → `AppleAPFSContainer` → `IOMedia disk6s1`（Whole = false）→ `IOMedia disk6`（Whole = true）
  第一個 `Whole == true` 的 IOMedia 就是實體整碟
- 裝置名稱：實體整碟的 `DeviceVendor` + `DeviceModel`，都沒有時用 `MediaName`。選單上的列名是第一個卷宗的名稱（只有一個卷宗時暱稱取代它；多卷宗時暱稱取代下方灰字的裝置名稱）
- **磁碟映像檔**：`DeviceModel` 或 `DeviceProtocol` 是 `Disk Image` 時 `kind = .diskImage`，圖示不同，而且：不量介面速度、不觸發「接上硬碟」與空間不足通知、睡眠前不退出
- 序號：沿 IORegistry 往上找 `USB Serial Number` / `kUSBSerialNumberString` / `Serial Number`（`LinkSpeedService.serialNumber`），只顯示在資訊面板

## 退出流程
1. 找出這顆實體碟上所有 APFS 合成 container（卷宗的 whole disk ≠ 實體碟），逐一 `DADiskUnmount(kDADiskUnmountOptionWhole)`
   - **只對實體碟做整碟卸載不會連帶卸載 APFS 合成碟上的卷宗**，會回傳 EBUSY
2. 對實體碟 `DADiskUnmount(kDADiskUnmountOptionWhole)`
3. `DADiskEject`
4. 成功後裝置會從 DA 消失；`VolumeStore` 另外保留一則「可以安全拔除」提示 4 秒

DiskArbitration 的 callback 透過 `withCheckedContinuation` 轉成 async：context 傳入 retained 的 `ResultBox`，callback 內 `takeRetainedValue()` 後 resume。mount / unmount / eject 的 callback 簽章相同，共用一個 C 函式。

## 錯誤處理
| 狀態碼 | 意義 | 對應 |
|---|---|---|
| `kDAReturnBusy`、`kDAReturnExclusiveAccess` | 被佔用 | `DiskOperationError.busy` |
| `0xC000 \| EBUSY`（`0xC010`） | umount 回傳的 unix_err(EBUSY)，實測檔案被開啟時就是這個 | `.busy` |
| `kDAReturnNotPrivileged`（`0xF8DA0009`） | 沒有權限。曾在開啟 App Sandbox 時裝載內建讀卡機的 SD 卡遇到（未開沙盒時可以裝載）；保留對應，請使用者重插或改用磁碟工具程式 | `.failed` |
| 其他 | 顯示 `DADissenterGetStatusString`，沒有則顯示狀態碼 | `.failed` |

錯誤訊息顯示在該裝置列下方，下次成功操作或裝置消失時清除。

## 裝載
- 已接上但未掛載的卷宗會顯示「裝載」按鈕 → `DADiskMount`（預設掛載點）；成功時一併清掉那顆裝置的退出失敗狀態
- 掛載失敗的訊息存在 `VolumeStore.mountErrors`（以卷宗為 key），顯示在該卷宗下方；再按「裝載」就是重試。不與退出失敗共用 `ejectStates`，因為退出失敗面板的「再試一次」與「強制退出」會退出整顆裝置

## 佔用偵測
實作：`PopDisk/Services/BusyProcessService.swift`

退出回傳 busy 時，掃描所有程式（`proc_listallpids`），符合以下任一條件就算佔用：
1. 開著的檔案位於該卷宗：`PROC_PIDLISTFDS` 取得 fd，對 vnode 類型的 fd 呼叫 `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`
2. 目前工作目錄位於該卷宗：`PROC_PIDVNODEPATHINFO` 的 `pvi_cdir`（例如終端機 `cd` 進去）
3. 執行檔本身在該卷宗：`proc_pidpath` 路徑前綴比對（直接從隨身碟執行的程式）

1、2 用 **裝置編號**（`vst_dev` 對 `stat(mountPath).st_dev`）比對，不受 symlink 或路徑寫法影響。
掃描在背景執行緒（`Task.detached`）進行，幾百個程式約數十毫秒。

### 對應到 App
- 沿 `PROC_PIDT_SHORTBSDINFO` 的 `pbsi_ppid` 往上找，第一個 `activationPolicy == .regular` 的 `NSRunningApplication` 就是所屬 App
- 例如 `zsh`（cwd 在隨身碟）→ 所屬 App 為「終端機」；本身就是 App（例如 Preview）時 `isApp == true`

### 結束並重試
- 本身是 App：`NSRunningApplication.terminate()`（正常結束，App 會詢問是否儲存）
- 其他程式（例如 shell）：`SIGTERM` 只結束那個程序，不會關掉整個終端機。互動式 shell（zsh 等）會忽略 `SIGTERM`，1 秒後還在就補送 `SIGHUP`（和關閉終端機視窗時相同，shell 會正常結束）
- 以 `kill(pid, 0)` 輪詢最多 10 秒，然後自動重試退出；若 App 還停在儲存對話框，重試會再次列出它

- 網路碟退出被佔用時走同一套偵測與結束流程（`NetworkStore.terminate`）

### 限制
- 只看得到目前使用者的程式。root 擁有的程式（Spotlight 的 `mds` 等）無法檢查，這時顯示「找不到是哪個程式」
- DiskArbitration 本身會處理 Spotlight / fseventsd，通常不會因為它們而退出失敗

## 強制退出
- 只在一般退出失敗後出現（「強制退出…」），必須經過 `NSAlert` 確認
  - 選單列面板裡 SwiftUI 的 `.alert` 不穩定，所以用 `NSAlert.runModal()`，並先 `NSApp.activate()`
- container 與實體碟都加上 `kDADiskUnmountOptionForce` 卸載，再 `DADiskEject`

## 測試方式
不需要實體硬碟，可以用磁碟映像檔模擬：
```sh
hdiutil create -size 60m -fs APFS  -volname TestAPFS  apfs.dmg   # 會產生合成碟，測 container 卸載
hdiutil create -size 60m -fs ExFAT -volname TESTEXFAT exfat.dmg
hdiutil attach apfs.dmg; hdiutil attach exfat.dmg
diskutil unmount disk7s1        # 測「裝載」按鈕
(cd /Volumes/TestAPFS && exec sleep 300) &              # cwd 佔用
(exec tail -f /Volumes/TESTEXFAT/f.txt > /dev/null) &   # 開檔佔用
lsof /Volumes/TestAPFS /Volumes/TESTEXFAT              # 對照偵測結果
```
