# 速度量測

實作：`PopDisk/Services/LinkSpeedService.swift`、`PopDisk/Models/LinkInfo.swift`

## 介面協商速度

### 外接碟（IOKit）
`DiskArbitrationService.makeDrive` 以實體整碟的 `DADiskCopyIOMedia` 呼叫 `LinkSpeedService.externalLink`，沿 IORegistry（IOService plane）往上收集所有上層節點：

| 找到的節點 | 讀取的屬性 | 顯示 |
|---|---|---|
| `AppleSDXCSlot`（內建讀卡機，優先判斷） | `Speed Mode`（實測 `"UHS: SDR104"`），對應 SD 規格的匯流排上限 | `SD · UHS-I 104 MB/s`；沒見過的模式照字串顯示 |
| `IOUSBHostDevice` | `USBSpeed`（見下表）；有 `UsbLinkSpeed`（bit/s）時優先使用 | `USB 10 Gb/s` |
| `IOPCIDevice` | `IOPCIExpressLinkStatus` | `PCIe 3.0 ×4`；上層有 Thunderbolt 類別時為 `Thunderbolt · PCIe 3.0 ×4` |
| 都沒有 | `Protocol Characteristics` → `Physical Interconnect` | 只顯示介面名稱；`Virtual Interface`（磁碟映像檔）不顯示 |

`USBSpeed` 的值（`IOUSBHostFamilyDefinitions.h` 的 `tIOUSBHostConnectionSpeed`，依 XHCI 規格，**Low 與 Full 的順序是反的**）：

| 值 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| 速度 | Full 12 Mb/s | Low 1.5 Mb/s | High 480 Mb/s | Super 5 Gb/s | SuperPlus 10 Gb/s | SuperPlusBy2 20 Gb/s |

內建讀卡機是接在 PCIe 上的晶片（實測 PCIe 2.0 ×1，約 500 MB/s），照一般規則往上找會先找到它，顯示的速度遠高於 SD 卡能跑的速度，對使用者沒有意義；真正的瓶頸是卡協商到的匯流排模式，所以 SD 卡改顯示 `Speed Mode`，讀卡機的 PCIe 通道放在資訊面板的「讀卡機」（`LinkInfo.readerDetail`）。讀卡機支援 UHS-II 但卡只支援 UHS-I 時不提示，原因同下方「刻意不提示」：要換卡才能改善。

| `Speed Mode` 含 | 顯示 |
|---|---|
| `HD312` / `FD312`、`FD156` | UHS-II 312 / 156 MB/s |
| `SDR104`、`SDR50` / `DDR50`、`SDR25`、`SDR12` | UHS-I 104、50、25、12.5 MB/s |
| `High Speed`、`Default` | High Speed 25 MB/s、Default Speed 12.5 MB/s |

UHS-II 的字串是依規格名稱推測（手上沒有 UHS-II 卡可實測），對不上時會照系統字串顯示。

`IOPCIExpressLinkStatus` 是 PCIe Link Status 暫存器：bit 0–3 為速度代號（1 = 2.5 GT/s、2 = 5、3 = 8、4 = 16、5 = 32），bit 4–9 為通道數，`0xFFFF` 代表沒有連線。內建讀卡機沒插卡時晶片會斷電，Status 讀到 `0xFFFF`（實測剛插卡、App 第一次讀取時也可能遇到），資訊面板的「讀卡機」這時改讀 `IOPCIExpressLinkCapabilities`（格式相同，是晶片支援的最高速度；實測與連線時的 Status 一樣是 PCIe 2.0 ×1）；一般 PCIe／Thunderbolt 硬碟不退而求其次，避免顯示比實際快的速度。顯示的頻寬已扣除編碼開銷（Gen1/2 為 8b/10b，Gen3 以上為 128b/130b）。

Thunderbolt port 本身的 `Current Link Speed` 代號沒有公開文件，所以不顯示 Thunderbolt 鏈路速率，改顯示硬碟實際走的 PCIe 通道（這才是外接 NVMe 的瓶頸）。

### 網路碟
1. 以 `NWConnection` 對伺服器建立 TCP 連線（SMB 445、NFS 2049、AFP 548、WebDAV 依網址 80/443 或指定 port），從 `currentPath.availableInterfaces.first` 得知走哪張網卡
2. 延遲 = TCP 連線建立時間，不含名稱解析。第一次用伺服器名稱連線，只用來取得網卡與解析後的位址（`currentPath.remoteEndpoint`）；再直接連這個位址兩次，取較短者。每次 3 秒逾時；第一次就連不上時不再重試
   - 用名稱連線每次都會重新解析：2026-10-27 對 Bonjour 的 NAS 實測，用名稱連 62–82 ms，直接連位址 7–8 ms，所以不能拿名稱連線的時間當延遲
   - 從 Finder 側邊欄（Bonjour）連上的 SMB，位址是服務名稱（例如 `MyNAS._smb._tcp.local`），DNS 解析不到。主機名稱含 `_tcp` / `_udp` 時改用 `NWEndpoint.service` 由 Bonjour 解析，連到服務公告的 port
3. 網卡速率：
   - Wi‑Fi：CoreWLAN `CWInterface.transmitRate()`（Mb/s）。`ifi_baudrate` 對 Wi‑Fi 不準（實測 1200 Mb/s 的連線回報 239 Mb/s）
   - 乙太網路：`sysctl(NET_RT_IFLIST2)` 的 `if_data64.ifi_baudrate`（64 位元，10 GbE 也不會溢位；`getifaddrs` 的 `if_data` 是 32 位元）
   - 本機（loopback）：顯示「這台 Mac」，不顯示速率
4. 量測時機：
   - 網路卷宗清單變動、選單打開：只量還沒量過的（新掛上的）。連不到的也記為量過，不會每次開選單都重試
   - 網路狀態改變（`NWPathMonitor`：換網路、插拔網路線、喚醒）：全部重量
   - 進行中又被要求時，等這輪結束再補量一次

## 速度受限提醒
只提示**使用者可以自己改善**的情況：

| 情況 | 判斷 |
|---|---|
| USB 3 裝置跑在 USB 2 速度 | `bcdUSB >= 0x0300` 且 `USBSpeed <= 3`（High Speed 以下）→ 接口、Hub 或線材問題 |
| 有線網路可用卻走 Wi‑Fi（提示「建議改用有線網路」，不寫「受限」：Wi‑Fi 不一定比較慢） | 走 Wi‑Fi，且 `NWPathMonitor` 的 `availableInterfaces` 有 `.wiredEthernet` |
| 乙太網路 ≤ 100 Mb/s | 網線或交換器可能只跑百兆 |

刻意**不提示** PCIe 速度低於裝置能力：例如 Gen4 SSD 裝在 PCIe 3.0 的 Thunderbolt 外接盒，使用者換接口也無法改善，提示只會造成困擾。

## 即時傳輸速度
實作：`PopDisk/Services/ThroughputService.swift`、`PopDisk/Stores/ThroughputStore.swift`

### 計數器來源
| 對象 | 來源 | inbound / outbound |
|---|---|---|
| 外接碟 | 實體整碟 IOMedia（`IOBSDNameMatching`）的上一層 `IOBlockStorageDriver` → `Statistics` 的 `Bytes (Read)` / `Bytes (Write)` | 讀取 / 寫入 |
| 網路碟 | 量測連線速度時得知的網卡（`LinkInfo.interfaceName`）→ `NET_RT_IFLIST2` 的 `ifi_ibytes` / `ifi_obytes` | 下載 / 上傳 |

速度 = 兩次取樣的差值 ÷ 經過時間。計數器變小（裝置重新接上）時當作 0。取樣開始後的第一次只當基準。

### 取樣排程
- 選單打開（`onAppear` / `onDisappear` 設定 `ThroughputStore.isMenuOpen`）：依設定每 1 / 2 / 5 秒
- 選單關著、但選單列要顯示箭頭或速度：每 max(設定值, 2) 秒
- 以上皆否：完全不取樣
- 設定改變、選單開關時呼叫 `ThroughputStore.reschedule()`：只在「需不需要取樣」改變時啟動或停止迴圈，已在取樣時不重啟（迴圈每輪讀取最新的間隔）。代價是新間隔要等目前這輪結束才套用

### 選單列
- 只計算**外接碟**的總和；網卡流量包含瀏覽器等其他 App，算進去會讓「傳輸中」一直亮
- 傳輸中的門檻：讀或寫 ≥ 64 KB/s，過濾 Spotlight 等零星 I/O
- 顯示優先順序：即時速度（設定開啟時）→ 傳輸箭頭 → 硬碟數量（超過 1 顆時）。三者在「設定 → 一般 → 選單列」各自開關，預設：數量開、箭頭開、速度關
- 數量包含外接碟與網路碟，不含使用者隱藏的（`PreferencesStore.visible`）
- 這個數量是 0 時圖示變淡（opacity 0.45），所以只剩隱藏的硬碟時也會變淡

### 列上的顯示
- 速度這一行一直保留（外接碟一律顯示；網路碟在知道網卡時顯示），讀、寫各自低於 1 KB/s（`TransferRate.displayThreshold`）時顯示「—」，避免一直出現「0 KB/s」
- 原本閒置時整行隱藏，開始或停止傳輸時列的高度會跟著變，整個面板上下跳動，所以改成固定佔位

### 限制
- 網路碟的數值是整張網卡的流量，macOS 沒有公開的單一掛載點計數器；滑鼠停在數字上會有說明
- 本機測試伺服器走 loopback（lo0），收送會同時計入，所以上下行數字相同
