#!/bin/zsh
# 建置 → Developer ID 簽章 → Apple 公證 → 壓縮成 zip → 加進公開 repo 的 appcast（不 push）
#
# 用法：scripts/release.sh
# 產出：build/release/PopDisk-<版本>.zip（已公證、已附公證票證），
#       build/public-repo/appcast.xml 多了這個版本（還沒推上去，最後會印出發佈步驟）
#
# 簽章與公證都使用 Xcode 已登入的開發者帳號（雲端管理的 Developer ID 憑證），
# 不需要另外產生 App 專用密碼。
set -euo pipefail
cd "${0:A:h}/.."

ARCHIVE=build/PopDisk.xcarchive
EXPORT=build/export
NOTARIZED=build/notarized
OUT=build/release
PUBLIC_REPO=chiehming113/PopDisk
APPCAST=build/public-repo/appcast.xml

# 發佈檔要能對應到某個 commit，所以不接受未提交的修改
if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作目錄有未提交的修改，請先 commit 再發佈" >&2
    exit 1
fi

# 發佈檔要能追溯到 GitHub 上的原始碼 commit（公開 repo 的同步 commit 會記下它）
git fetch --quiet --tags origin
if ! UPSTREAM=$(git rev-parse --verify --quiet '@{u}'); then
    echo "目前分支沒有設定 upstream，請先 push 到 GitHub" >&2
    exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$UPSTREAM" ]]; then
    echo "本機與 GitHub 上的分支不一致，請先 push（或 pull）再發佈" >&2
    exit 1
fi

# 致謝、Sparkle 金鑰、公開文件的私人資訊
scripts/preflight.sh

# 先檢查版本號，避免忘記改版本時覆蓋掉已發佈的 zip
# 失敗時不讓 set -e 直接結束，交給下面的檢查顯示原因；awk 讀完全部輸出，避免 xcodebuild 收到 SIGPIPE
SETTINGS=$(xcodebuild -project PopDisk.xcodeproj -scheme PopDisk -configuration Release -showBuildSettings \
    -clonedSourcePackagesDirPath build/SourcePackages) || true
VERSION=$(awk '$1 == "MARKETING_VERSION" && !found { print $3; found = 1 }' <<<"$SETTINGS")
BUILD=$(awk '$1 == "CURRENT_PROJECT_VERSION" && !found { print $3; found = 1 }' <<<"$SETTINGS")
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "讀不到 MARKETING_VERSION／CURRENT_PROJECT_VERSION（請看上面 xcodebuild 的錯誤訊息）" >&2
    exit 1
fi
ZIP="$OUT/PopDisk-$VERSION.zip"
if [[ -e "$ZIP" ]] || gh release view "v$VERSION" --repo "$PUBLIC_REPO" >/dev/null 2>&1; then
    echo "版本 $VERSION 已經發佈過（$ZIP 或公開 repo 的 v$VERSION 已存在），請先修改 MARKETING_VERSION" >&2
    exit 1
fi

# Sparkle 用 CFBundleVersion（CURRENT_PROJECT_VERSION）判斷新舊，一定要比已發佈的大，否則使用者收不到更新
scripts/sync-public-repo.sh
LATEST_BUILD=$(grep -o '<sparkle:version>[0-9]*</sparkle:version>' "$APPCAST" | grep -o '[0-9][0-9]*' | sort -n | tail -1) || true
if [[ -n "$LATEST_BUILD" ]] && (( BUILD <= LATEST_BUILD )); then
    echo "CURRENT_PROJECT_VERSION（$BUILD）要大於已發佈的 build $LATEST_BUILD" >&2
    exit 1
fi

rm -rf "$ARCHIVE" "$EXPORT" "$NOTARIZED"
mkdir -p "$OUT"

echo "==> 封存 Release 版 $VERSION"
# --timestamp 只在發佈時加：公證要求安全時間戳，但平常建置不該依賴 Apple 的時間戳伺服器
xcodebuild archive -project PopDisk.xcodeproj -scheme PopDisk -configuration Release \
    -archivePath "$ARCHIVE" -clonedSourcePackagesDirPath build/SourcePackages \
    -allowProvisioningUpdates -quiet OTHER_CODE_SIGN_FLAGS=--timestamp

echo "==> Developer ID 簽章並上傳公證"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$EXPORT" -allowProvisioningUpdates -quiet

echo "==> 等待公證完成（通常 1–5 分鐘）"
if [[ ! -d "$ARCHIVE" ]]; then
    echo "找不到封存檔 $ARCHIVE" >&2
    exit 1
fi
# 公證還沒完成時 -exportNotarizedApp 也會失敗，所以只能重試；
# 但遇到明確的錯誤（被退件、帳號或參數問題）要立刻停下並顯示原因，不要空等到逾時。
# 關鍵字刻意只挑明確的，太廣的（例如 invalid）可能出現在「還在處理中」的訊息裡
FATAL='reject|not signed in|no account|unknown option|unrecognized option'
last=""
for attempt in {1..40}; do
    if output=$(xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$NOTARIZED" -quiet 2>&1); then
        break
    fi
    # 用 here-string 而不是 pipe：grep -q 提早結束時，pipefail 會把「有符合」誤判成失敗
    if grep -qiE "$FATAL" <<<"$output"; then
        print -r -- "$output" >&2
        echo "公證失敗，詳細紀錄請到 Xcode → Window → Organizer 查看" >&2
        exit 1
    fi
    if [[ "$output" != "$last" ]]; then
        print -r -- "$output" | sed 's/^/    /'
        last=$output
    fi
    if (( attempt == 40 )); then
        echo "公證逾時（約 10 分鐘），請到 Xcode Organizer 查看狀態" >&2
        exit 1
    fi
    sleep 15
done

APP="$NOTARIZED/PopDisk.app"
echo "==> 驗證"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
# spctl 對本機規則允許的 App 也會回傳成功，所以要確認來源真的是公證過的 Developer ID
# spctl 不通過時會回傳非 0，不能讓 set -e 在這裡直接結束，否則看不到原因
assessment=$(spctl --assess -vvv --type execute "$APP" 2>&1) || true
print -r -- "$assessment"
if ! grep -q "source=Notarized Developer ID" <<<"$assessment"; then
    echo "App 不是以「Notarized Developer ID」通過 Gatekeeper，停止發佈" >&2
    exit 1
fi

# ditto 會保留擴充屬性與簽章；不要用 zip 指令
ditto -c -k --keepParent "$APP" "$ZIP"
# dSYM 只備份在私有 repo 的 Release（對照當機紀錄用），不公開
ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$OUT/PopDisk-$VERSION-dSYMs.zip"
# 記下建置用的 commit，publish-release.sh 會把私有 repo 的 tag 打在這裡
git rev-parse HEAD > "$OUT/PopDisk-$VERSION.commit"
echo "==> 完成：$ZIP"

scripts/appcast.sh "$ZIP" "$APPCAST"

cat <<NEXT

==> 還沒公開。確認無誤後執行（會先在私有 repo 留備份，再發佈到公開 repo）：
    scripts/publish-release.sh --dry-run $VERSION   # 先看會做什麼
    scripts/publish-release.sh $VERSION
    不發佈的話，還原 appcast：git -C build/public-repo checkout appcast.xml
NEXT
