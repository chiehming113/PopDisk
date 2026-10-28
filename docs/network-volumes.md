# 網路硬碟

實作：`PopDisk/Services/NetworkMountService.swift`、`KeychainService.swift`、`NetworkReconnectService.swift`、`PopDisk/Stores/NetworkStore.swift`

## 支援協定
| 協定 | 位址格式 | `f_fstypename` |
|---|---|---|
| SMB | `smb://host/share` | `smbfs` |
| NFS | `nfs://host/export/path`（`f_mntfromname` 為 `host:/path`，以路徑前最後一個 `:` 分隔，IPv6 主機轉成 `[fe80::1%25en0]`） | `nfs` |
| WebDAV | `http://` / `https://host/path` | `webdav` |
| AFP（只辨識，不主動支援） | `afp://host/share` | `afpfs` |

## 列出已掛載的網路卷宗
- 用 `getfsstat(MNT_NOWAIT)` 讀系統快取的掛載表，以 `f_fstypename` 判定協定，排除 `MNT_DONTBROWSE`
- **不用** `FileManager.mountedVolumeURLs` / `URL.resourceValues`：伺服器失聯時，這些 API 會對掛載點做 I/O，可能卡住主執行緒數十秒
- 容量取自同一筆 statfs（`f_blocks`、`f_bavail` × `f_bsize`），WebDAV 有些伺服器不回報容量，就不顯示容量條
- 伺服器位址由 `f_mntfromname` 推回：
  - smbfs：`//user@host/share` → `smb://user@host/share`（去掉 `WORKGROUP;` 前綴）
  - nfs：`host:/export/path` → `nfs://host/export/path`
  - webdav：本身就是 `http(s)://…`
- 變動通知：`NSWorkspace` 的 `didMount` / `didUnmount` / `didRenameVolume`
  - WebDAV 的 `didMount` 要等 `mount_webdav` 結束才會來（見下方），所以 `mount` 成功後也主動通知一次，選單不會一直顯示「連線」

## 掛載
- 掛載表裡已經有同一個分享（`ShareKey` 相同）時直接當成成功，不再呼叫 NetFS
- `NetFSMountURLAsync`，callback 排在 main queue，以 `withCheckedContinuation` 轉 async
- `open_options` 的 `UIOption`：有密碼時 `NoUI`；沒有密碼時 `AllowUI`，讓 macOS 跳出標準登入視窗（NetFS.h 的 `kNAUIOptionKey` 等是 `CFSTR` 巨集，Swift 看不到，直接寫字串值）
- 若 `NetFSMountURLAsync` 本身回傳非 0，不會呼叫 block，要自己 resume
- **同時每秒輪詢掛載表**：卷宗出現就視為成功並 `NetFSMountURLCancel`；逾時（不跳視窗 60 秒、可能跳登入視窗 300 秒）視為連不到伺服器
  - 原因：實測 NetFS 的回呼要等 `/sbin/mount_webdav` 結束才會來，而在本機 WsgiDAV 測試伺服器上，卷宗 1 秒內就可讀寫，`mount_webdav` 卻要約 70–90 秒才結束（某個請求等到逾時）
  - 這段期間 DiskArbitration 卸載會回傳 `kDAReturnBadArgument`（`0xF8DA0003`），`unmount(2)` 連 `MNT_FORCE` 都是 `EBUSY`；`mount_webdav` 結束後即可正常卸載。UI 會顯示錯誤與「再試一次」

| NetFS 狀態碼 | 對應 |
|---|---|
| 0、`EEXIST` | 成功（已掛載也算成功） |
| `ECANCELED`、-128 | 使用者取消，不顯示錯誤 |
| `EAUTH`、`ENEEDAUTH`、`EACCES`、`EPERM` | 帳號或密碼錯誤 |
| `EHOSTUNREACH`、`EHOSTDOWN`、`ENETUNREACH`、`ETIMEDOUT`、`ECONNREFUSED`、`ENOTCONN` | 連不到伺服器 |
| `ENOENT` | 分享資料夾不存在 |

## 退出
- `DADiskCreateFromVolumePath` + `DADiskUnmount`，與外接碟共用 `DiskArbitrationService` 的 busy 判斷與佔用程式偵測
- 強制退出加上 `kDADiskUnmountOptionForce`

## 常用清單與密碼
- `NetworkFavorite`（名稱、位址、使用者名稱、啟動時連線）以 JSON 存在 UserDefaults `networkFavorites`，**不含密碼**
- 密碼存登入鑰匙圈的 internet password：`server` + `account` + `path`，`label` 固定為 `PopDisk: <host>`
  - 加 label 是為了只讀寫 PopDisk 自己的項目；若去讀 Finder 存的密碼，macOS 會跳出授權詢問
  - 鑰匙圈依簽章判斷是不是同一個 App：Debug 版（Apple Development）、正式版（Developer ID）各會詢問一次；用 ad-hoc 簽章建置時（不是團隊成員，見 [development.md](development.md)）每次重新建置都會再問，選「永遠允許」即可
- 編輯時密碼欄留空 = 保留原本密碼；改了位址或帳號時，舊密碼會搬到新的 key（鑰匙圈的 key 不含協定與埠號，新舊可能是同一個項目，所以先刪再寫）
- 刪除常用項目時，一併刪除鑰匙圈裡的密碼
- 編輯視窗的位址若含使用者名稱（`smb://user@host/share`），存檔時拆到使用者欄位，`url` 本身不含帳號密碼；名稱留空時用路徑最後一段（沒有就用主機名稱）
- 支援的位址：`NetworkProtocol(scheme:)` 認得的 `smb`／`cifs`、`nfs`、`http`／`https`、`afp`，而且要有主機名稱，否則「儲存」不能按
- 已連線但不在清單內的網路碟，列上會有 ☆（⋯ 選單也有「加入常用網路硬碟」），按下就以掛載資訊建立常用項目（不含密碼）
- 選單裡還沒連上的常用項目（`disconnectedFavorites`）顯示在已連線的網路碟下方，有「連線」按鈕；連線失敗的訊息存在 `connectErrors`，編輯存檔後清除
- 分享比對用 `ShareKey`（協定類別 + 主機 + 路徑，忽略使用者名稱與大小寫），http / https 視為同一類

## 自動掛載與重連
見 [automation.md](automation.md)。

## 測試方式
沒有 NAS 時，可以在本機用 WsgiDAV 架 WebDAV 伺服器：
```sh
python3 -m venv davenv && davenv/bin/pip install wsgidav cheroot
davenv/bin/wsgidav --config dav.yaml   # 設定 basic auth 帳號，provider_mapping 指到測試資料夾
```
然後在 PopDisk 加入 `http://127.0.0.1:<port>/share`。SMB、NFS 需要實際的 NAS 或另一台開了檔案分享的 Mac。
