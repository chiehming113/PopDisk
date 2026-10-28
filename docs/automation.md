# 自動化行為

| 行為 | 觸發條件 | 預設 | 實作 |
|---|---|---|---|
| 啟動時自動連線 | App 啟動後網路第一次可用（`NWPathMonitor` 狀態 satisfied） | 依每個常用項目的「PopDisk 啟動時連線」 | `NetworkStore.mountFavoritesAtLaunch` |
| 斷線自動重連 | 喚醒後 5 秒、或網路從斷線恢復後 2 秒；15 秒後再試一次 | 開（設定 → 網路硬碟） | `NetworkReconnectService` |
| 睡眠前退出外接碟 | IOKit `kIOMessageSystemWillSleep` | 關 | `AutomationController` + `SystemSleepService` |
| 登入時開啟 PopDisk | `SMAppService.mainApp` | 關 | `LoginItemService` |
| 接上硬碟通知 | 外接碟清單出現新的實體碟（磁碟映像檔、啟動後 5 秒內的不算） | 關 | `AutomationController.drivesChanged` |
| 退出結果通知 | `VolumeStore.onEjectFinished`，**只在選單關著時**（快捷鍵、睡眠前退出） | 開 | `AutomationController.ejectFinished` |
| 空間不足通知 | 硬碟清單變動時（用 `drives()` 剛讀到的容量）與每 60 秒檢查（重新讀取容量，因為拷貝時空間會持續變少）；剩餘 < 5 / 10 / 15 / 20%。對象是實體外接碟已裝載的卷宗（不含磁碟映像檔）與網路碟（用 `getfsstat` 的快取值，伺服器失聯也不會卡住）；隱藏的也會檢查 | 開（10%） | `AutomationController.checkFreeSpace` |
| 全域快捷鍵 | Carbon `RegisterEventHotKey` | 未設定 | `HotKeyService` |

「開機自動連線」＝ 登入時開啟 PopDisk ＋ 常用項目勾選「PopDisk 啟動時連線」。

## 斷線重連的判斷
`NetworkReconnectService` 記錄目前已掛載的伺服器位址。卷宗消失時：

- **視為意外斷線、列入待重連**：系統正在睡眠、喚醒後 60 秒內、或網路處於斷線狀態
  （macOS 常在喚醒後才回報網路卷宗被卸載，所以需要喚醒後的寬限時間）
- **不重連**：
  - 由 PopDisk 退出的（退出前先 `willEject`，失敗時 `ejectFailed` 還原）
  - 網路正常、清醒時消失的，例如使用者從 Finder 退出

重連時不跳任何視窗：
- 常用項目：帶入 Keychain 中的帳號密碼
- 不在常用清單的：用掛載時的位址（含使用者名稱），交給系統既有的認證；失敗就等下一次觸發

PopDisk 結束後再開啟時，待重連清單不會保留（只保存在記憶體）。

## 睡眠前退出
- `NSWorkspace.willSleepNotification` 只是通知、不會等 App 做完，硬碟可能還沒退出 Mac 就睡了
- 改用 `IORegisterForSystemPower`：收到 `kIOMessageSystemWillSleep`（`0xE0000280`）後先退出，完成才呼叫 `IOAllowPowerChange`，系統最多等約 30 秒
- `kIOMessageCanSystemSleep`（`0xE0000270`，閒置睡眠前的詢問）一律立即允許
- `kIOMessage*` 是 `iokit_common_msg()` 巨集，Swift 看不到，程式裡直接寫數值
- 只退出實體碟（`kind == .disk`），磁碟映像檔不受睡眠影響
- 選單中隱藏的實體碟也會退出：隱藏只影響顯示，睡眠時的資料損壞風險一樣
- 退出失敗的硬碟記下來，`didWake` 後發通知

## 通知
- `UNUserNotificationCenter`，第一次要發通知時才請求權限；同時發出的多則通知都等同一個授權 Task 完成才送出（授權未決定前送出的會被丟掉）
- PopDisk 是 LSUIElement App，常被視為前景；必須實作 `willPresent` 回傳 `[.banner, .sound]`，否則通知不會顯示
- 同一顆碟的同類通知用固定 identifier，新的會取代舊的：`connected-<BSD>`、`eject-<BSD>`、`space-<卷宗 BSD 名稱或網路碟掛載路徑>`、`sleep-eject`、`update-available`（`UpdateStore` 的背景更新提醒）
- 「設定 → 通知」開啟時查詢授權狀態，被使用者關掉（`.denied`）時顯示提示與「打開系統設定」
- 空間警示發過一次後，要回到門檻以上才會再發

## 全域快捷鍵
- `RegisterEventHotKey` 不需要輔助使用權限；簽章 `'PpDk'`，id 對應 `HotKeyService.Action`
- 錄製時用 `NSEvent.addLocalMonitorForEvents(.keyDown)`；必須含 ⌘ / ⌥ / ⌃（避免單一按鍵被全域攔截），esc 取消、⌫ 清除
- 已被其他 App 註冊的組合會註冊失敗，設定畫面顯示「已被其他 App 使用」（`AppSettings.hotKeyConflicts`）
- 錄製期間（`AppSettings.recordingHotKey`）先取消所有全域快捷鍵：Carbon 比 `NSEvent` local monitor 先收到按鍵，不取消的話按到已設定的組合會直接執行那個動作。錄製結束、切換分頁或 PopDisk 失去焦點時重新註冊；同時只能有一個欄位在錄製
- 兩個動作不能用同一組：錄製時就擋下並顯示「已被 PopDisk 的另一個快捷鍵使用」，原本那個快捷鍵不受影響
- 「全部退出」快捷鍵與選單的「全部退出」一樣，只退出選單上看得到的硬碟（`PreferencesStore.visible`），使用者隱藏的不動
- 快捷鍵在 `AutomationController.start()` 註冊一次，之後設定變更時（`AppSettings.onHotKeysChange`）重新註冊
- 鍵名用 `UCKeyTranslate` 依目前鍵盤配置轉換
- 「打開選單」：`MenuBarExtra` 沒有公開 API 可以打開面板。先從 `NSStatusBarWindow` 取得 `NSStatusItem`（私有的 `statusItem` 屬性，先用 `responds(to:)` 確認）
  - macOS 27 起選單列項目由系統代管（`NSSceneStatusItem`），點擊不經過 `NSStatusBarButton` 的 target／action（兩者都是 nil，`performClick`、`accessibilityPerformPress`、自己送滑鼠事件都打不開）。實際流程是系統開啟 expanded interface session → `-[NSStatusItem _beginExpandedInterfaceSession:]` → SwiftUI 的 `WindowMenuBarExtraBehavior.statusItem(_:didBegin:)` 顯示面板。
  - 打開：呼叫私有的 `_requestExpandedInterfaceSession`（和點擊同一條路，選單列圖示也會變成按下的樣子）；關閉：`statusItem.expandedInterfaceSession?.cancel()`（macOS 27 公開 API）。session 不是 nil 代表面板開著，以此切換
  - macOS 26 以前沒有這套機制，退回對按鈕呼叫 `performClick`（未在舊系統實測）

## 登入項目
- `SMAppService.mainApp.register()`；狀態 `.requiresApproval` 時提示並提供「打開系統設定」
- 開發中的 Debug 版本也能註冊，但登入項目會指向 `build/` 裡的那份 App，測試完記得關掉
