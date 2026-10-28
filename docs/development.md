# 開發指南

## 環境
- macOS 15 以上（開發機目前為 macOS 27）
- Xcode 27.1 / Swift 6.4（專案設定 `SWIFT_VERSION = 6.0`，啟用完整 strict concurrency）
- 唯一的第三方套件是 Sparkle（Swift Package，版本固定在 `PopDisk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`），第一次建置時自動下載

## 專案設定重點
| 設定 | 值 | 原因 |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | 15.0 | 使用 `Tab`、`openSettings`、`@Observable` |
| `ENABLE_APP_SANDBOX` | NO | 找出佔用的程式（libproc）、結束程式、直接開啟卷宗、裝載內建讀卡機的 SD 卡在沙盒內都做不到；只在 GitHub 發佈，不上 App Store |
| `ENABLE_HARDENED_RUNTIME` | YES | Developer ID 公證需要 |
| `GENERATE_INFOPLIST_FILE` | YES | Info.plist 內容寫在 `INFOPLIST_KEY_*` |
| `INFOPLIST_FILE` | `Config/Info.plist` | `INFOPLIST_KEY_*` 只支援 Apple 定義的鍵，Sparkle 的 `SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks` 要寫在這裡（與產生的內容合併）。放在 `PopDisk/` 外面，才不會被當成資源複製進 App |
| `INFOPLIST_KEY_NSHumanReadableCopyright` | `© 2026 MingTW` | 「關於」頁顯示 |
| `INFOPLIST_KEY_LSUIElement` | YES | 只出現在選單列 |
| `CODE_SIGN_IDENTITY` | `Apple Development` | 自動簽章；匯出時改用 Developer ID |
| `DEVELOPMENT_TEAM` | `L36G2DM6YF` | |
| `PRODUCT_BUNDLE_IDENTIFIER` | Release：`com.chiehming.PopDisk`；Debug：`com.chiehming.PopDisk.debug` | Debug 版的設定、登入項目、通知權限與正式版分開，開發測試不會動到日常在用的設定 |
| `INFOPLIST_KEY_CFBundleDisplayName` | Release：`PopDisk`；Debug：`PopDisk Debug` | 「系統設定」的通知、登入項目等清單裡會同時出現兩個，用名稱區分（App 內的文字不變） |

Xcode 專案用 **file-system synchronized group**（objectVersion 77）：`PopDisk/` 資料夾內的檔案自動屬於 App target，新增／搬移檔案不用改 `project.pbxproj`。加入 Swift Package 是唯一要改 `project.pbxproj` 的情況。

## 建置與執行
```sh
# 建置（產物放在 repo 內的 build/，已被 .gitignore 忽略）
# -clonedSourcePackagesDirPath 讓 Sparkle 的工具（sign_update 等）固定在 build/SourcePackages/artifacts/sparkle/Sparkle/bin/
xcodebuild -project PopDisk.xcodeproj -scheme PopDisk -configuration Debug -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages build

# 執行
pkill -x PopDisk; open build/Build/Products/Debug/PopDisk.app
```
也可以直接用 Xcode 開 `PopDisk.xcodeproj`，按 ⌘R。

不是 `L36G2DM6YF` 團隊成員（例如從 GitHub clone 下來）時，Xcode 找不到這個團隊的憑證會建置失敗，改用 ad-hoc 簽章：
```sh
xcodebuild -project PopDisk.xcodeproj -scheme PopDisk -configuration Debug -derivedDataPath build \
    -clonedSourcePackagesDirPath build/SourcePackages CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```
ad-hoc 簽章每次建置都會變，所以存取鑰匙圈時每次重新建置都會再詢問一次。

自己建置的版本仍會向官方的 appcast 檢查更新。官方的新版本是用維護者的 Developer ID 簽章，和自己建置的簽章不同，Sparkle 的安全檢查可能不讓它安裝（還沒實際測過）；要用官方版本時，請直接從 GitHub Releases 下載。

## 測試語系
```sh
# 用英文啟動
open build/Build/Products/Debug/PopDisk.app --args -AppleLanguages '(en)'
# 用繁體中文啟動
open build/Build/Products/Debug/PopDisk.app --args -AppleLanguages '(zh-Hant)'
```

## 檢查翻譯是否齊全
建置後，Xcode 會把程式中的字串抽到 `.stringsdata`，可與 String Catalog 比對：
```sh
python3 -c "
import json,glob
keys=set()
for f in glob.glob('build/Build/Intermediates.noindex/**/*.stringsdata', recursive=True):
    for t in json.load(open(f)).get('tables',{}).values():
        keys|={e['key'] for e in t}
cat=json.load(open('PopDisk/Localizable.xcstrings'))['strings']
print('missing:', sorted(k for k in keys if k not in cat) or 'none')"
```
注意：`Button(cond ? "A" : "B")` 這種三元運算式會推斷成 `String`，不會被抽出也不會翻譯，要寫成 `cond ? LocalizedStringKey("A") : "B"`。

## 更新 App 圖示
App 圖示是 Icon Composer 格式的 `PopDisk/AppIcon.icon`（2026-10-27 起）：
- `icon.json`：背景色（純黑）、陰影、玻璃效果等設定，由系統依 macOS 版本繪製
- `Assets/glyph.png`：前景圖層，1024×1024 透明底、白色圖案置中（約 60%）

macOS 26 起，系統會把不符合新規格的舊式圖示（自己畫圓角方形、四周留白）放進灰色底框；`.icon` 格式不會。給 macOS 15 的舊格式 `AppIcon.icns` 由 Xcode 建置時自動產生（有留邊、圓角與陰影）。可以用 Xcode 附的 Icon Composer 打開 `AppIcon.icon` 調整，存檔後就是新的 `icon.json`。

圖案原稿是 `assets/icon/glyph-source.pxd`（Pixelmator Pro，匯出成 `glyph-source.png`，黑色圖案、白色鏤空）。改圖案後：
```sh
# 黑白原稿轉成單色遮罩（白色變透明），選單列圖示與 App 圖示共用
swift assets/menubar/make-glyph.swift assets/icon/glyph-source.png assets/menubar/glyph.png
# 選單列圖示（template，16pt）
M=PopDisk/Assets.xcassets/MenuBarIcon.imageset
sips -z 16 16 assets/menubar/glyph.png --out $M/MenuBarIcon.png; sips -z 32 32 assets/menubar/glyph.png --out $M/MenuBarIcon@2x.png
# App 圖示的前景圖層
swift assets/icon/make-icon.swift assets/menubar/glyph.png PopDisk/AppIcon.icon/Assets/glyph.png
# 1024px 預覽（assets/icon/AppIcon-1024.png，只供檢視，不會打包進 App）
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" PopDisk/AppIcon.icon \
    --export-image --output-file assets/icon/AppIcon-1024.png --platform macOS --rendition Default --width 512 --height 512 --scale 2
```
改完圖示後，系統可能還顯示舊圖示（圖示快取）。用 `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <App 路徑>` 重新登記再看。

## 更新 README 截圖
Debug 版有截圖模式（`PopDisk/Debug/SnapshotRenderer.swift`）：在螢幕外的視窗畫出選單與設定畫面再存成 PNG。
不需要螢幕錄製權限，也不會拍到螢幕上的其他內容。
```sh
# 先接上要入鏡的硬碟：README 用的是測試映像檔 POPEXFAT（exFAT）、PopTestAPFS（APFS）與本機 WsgiDAV 的 share
A=build/Build/Products/Debug/PopDisk.app/Contents/MacOS/PopDisk
D=/tmp/shots; mkdir -p $D
# -snapshotVolumes 只拍指定名稱的硬碟與常用網路硬碟，不會拍到自己接著的硬碟或 NAS（只篩選畫面，不會改動設定）
V='POPEXFAT,PopTestAPFS,share'
$A -snapshotDirectory $D -snapshotVolumes $V -AppleLanguages '(zh-Hant)'
$A -snapshotDirectory $D -snapshotVolumes $V -snapshotSuffix _en -AppleLanguages '(en)'   # 後綴不能以 - 開頭
```
產生 `menu-light.png`、`menu-dark.png`、`settings.png`（英文版為 `menu-light_en.png` 等）。`assets/screenshots/menu-light-en.png` 是英文版選單截圖，目前 README 沒有用到，但會同步到公開 repo，重拍時一起更新。截圖用的是 Debug 版的設定 `com.chiehming.PopDisk.debug`（暱稱、排序、常用清單），需要的話先從正式版複製：`defaults export com.chiehming.PopDisk - | defaults import com.chiehming.PopDisk.debug -`。另外也會輸出「設定 → 關於」的 `about.png`。設定畫面的分頁列在螢幕外畫不出來，頂端 70px 要裁掉；「關於」只裁掉底部空白。`sips -c` 實測（2026-10-27）輸出大小不變、沒有裁切，改用 CoreGraphics 的小腳本 `scripts/crop-screenshot.swift`：
```sh
swift scripts/crop-screenshot.swift $D/settings.png assets/screenshots/settings.png 70 1100   # 上方裁掉 70px，保留 1100px
swift scripts/crop-screenshot.swift $D/about.png assets/screenshots/about.png 0 1065
cp $D/menu-light.png $D/menu-dark.png assets/screenshots/; cp $D/menu-light_en.png assets/screenshots/menu-light-en.png
```
數字是 2026-10-27 的版面（設定截圖高 600pt = 1200px；「關於」2026-10-28 加了「授權條款」後改裁到 1065，只留到授權條款的說明文字）；內容變長時先看圖再調整。

## 簽章、發佈與 App 內更新測試
完整流程、資料放在哪裡、發佈前檢查清單都在維護者內部文件 `internal/release-process.md`（不公開）。**發佈前一定要先讀那份文件。**

## 手動測試清單
用 Claude 的 computer use 測試時：computer use 找不到 `LSUIElement` 的 App，要把 Debug 版複製到 `~/Applications`、用 `PlistBuddy` 把 `LSUIElement` 改成 false，再用原本的 Apple Development 憑證與 entitlements 重新簽章（不改簽章身分，鑰匙圈存取才不會變）。選單列面板不會讓 PopDisk 變成前景 App，按鍵要先把另一個 App 切到前景；面板裡的按鈕用 AX（`app_click` 的 element_index）比用座標可靠。

- [ ] 外接碟插拔時列表即時更新；退出後 `diskutil list` 中已消失
- [ ] 開著外接碟上的檔案再退出 → 列出佔用 App；按「結束」後自動再退出成功；終端機停在卷宗裡時顯示「zsh／在終端機中」，「結束」只結束那個 shell；與 `lsof +D /Volumes/<name>` 比對
- [ ] 強制退出會先出現確認對話框，標題用硬碟的暱稱（有取暱稱時）
- [ ] 介面速度與「系統資訊 → USB / Thunderbolt」一致；網卡速率與 `networksetup -getMedia <device>` 一致
- [ ] USB 3 SSD 接 USB 2 Hub／線材 → 出現「連線速度受限」
- [ ] 複製大檔時速度與 `iostat -d -w 1`（外接）/ `nettop`（網路）量級一致
- [ ] SMB、NFS、WebDAV 各自能掛載、退出；常用網路硬碟一鍵掛載會帶入 Keychain 密碼
- [ ] 從 Finder 側邊欄（Bonjour）連上的 SMB 也量得到延遲，數值接近 `ping <主機>.local`；選單只顯示伺服器名稱（例如 `MyNAS`）
- [ ] 內建讀卡機的 SD 卡會出現在清單、可退出；卸載後按「裝載」能重新裝載；連線顯示 `SD · UHS-…`，⌘I 資訊面板有「讀卡機 PCIe …」
- [ ] 關閉再開啟 Wi‑Fi → 網路碟自動重連；手動退出的不重連
- [ ] 開啟「睡眠前自動退出」後 `pmset sleepnow` → 喚醒時外接碟已退出；退出失敗會在喚醒後通知
- [ ] 「登入時自動開啟」出現在「系統設定 → 一般 → 登入項目」（Debug 版的 bundle id 不同，會是另一個項目；測試完記得關掉）
- [ ] 全域快捷鍵在其他 App 前景時可觸發「全部退出」；「打開選單」按一次打開面板、再按一次關閉
- [ ] 英文／繁中切換後文字都正確
- [ ] 選單內 ↑↓ 選取、↩ 在 Finder 開啟、⌘E 退出、⇧⌘E 全部退出、⌘I 資訊
- [ ] ⋯ 選單：在 Finder／終端機中開啟、在 Finder 中顯示、拷貝路徑
- [ ] ⋯ 選單：取暱稱（NSAlert 輸入框）、釘選、隱藏；「設定 → 硬碟」可改圖示、拖曳 ≡ 排序、取消隱藏
- [ ] 「設定 → 通知」錄製快捷鍵；與其他 App 衝突時顯示「已被其他 App 使用」
- [ ] 選單關著時用快捷鍵全部退出 → 收到「可以安全拔除」通知
- [ ] 剩餘空間低於門檻 → 收到一次通知；清出空間後再變少會再通知（實體外接碟與網路碟會觸發，磁碟映像檔不會）
- [ ] 選單列圖示：沒有硬碟時變淡、多顆時顯示數量、傳輸中顯示箭頭／速度
- [ ] App 內更新（步驟見維護者內部文件 `internal/release-process.md`「測試 App 內更新」）：「檢查更新…」找到新版、安裝後自動重新開啟、版本變新；設定與鑰匙圈密碼都還在
- [ ] 背景檢查找到新版時，選單底部出現「PopDisk x.y 已推出／安裝…」並收到通知；按「安裝…」跳出更新視窗，處理後提示消失
- [ ] 「設定 → 一般」關掉「自動檢查更新」後不再自動檢查；「設定 → 關於」的連結都能打開、「拷貝系統資訊」的內容正確
