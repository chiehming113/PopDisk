#!/bin/zsh
# 發佈前的自動檢查（release.sh 一開始會執行；也可以單獨執行）
#
# 用法：scripts/preflight.sh [--public-only] [commit]
#   --public-only  只做第 3 項（sync-public-repo.sh 用；只改文件時不需要私鑰）
#   commit         第 3 項要檢查哪個 commit 的內容（預設 HEAD；發佈時是建置用的 commit）
# 檢查：
#   1. 開源軟體致謝（PopDisk/Acknowledgements.txt）含有目前 Sparkle 版本的完整 LICENSE
#   2. 鑰匙圈裡的 Sparkle 私鑰與 Config/Info.plist 的公鑰是同一組（不同的話使用者會拒絕更新）
#   3. 要同步到公開 repo 的檔案（scripts/export-public.sh 匯出的整份內容）沒有私人資訊（internal/public-denylist.txt），
#      也沒有連到不公開的 internal/、CLAUDE.md；App 內的授權全文（PopDisk/License.txt）和 LICENSE 相同、繁中譯文和 LICENSE.zh-Hant.md 相同；
#      README 的第三方授權全文和 PopDisk/Acknowledgements.txt 相同
set -euo pipefail
cd "${0:A:h}/.."

failed=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1" >&2; failed=1; }

PUBLIC_ONLY=false
if [[ "${1:-}" == "--public-only" ]]; then
    PUBLIC_ONLY=true
    shift
fi
COMMIT=${1:-HEAD}

echo "==> 發佈前檢查"

if ! $PUBLIC_ONLY; then
# 1. 致謝
LICENSE_FILE=build/SourcePackages/checkouts/Sparkle/LICENSE
if [[ ! -f "$LICENSE_FILE" ]]; then
    xcodebuild -resolvePackageDependencies -project PopDisk.xcodeproj -scheme PopDisk \
        -clonedSourcePackagesDirPath build/SourcePackages -quiet
fi
if python3 -c 'import sys; sys.exit(0 if open(sys.argv[2]).read().strip() in open(sys.argv[1]).read() else 1)' \
        PopDisk/Acknowledgements.txt "$LICENSE_FILE"; then
    ok "開源軟體致謝與 Sparkle 的 LICENSE 一致"
else
    bad "PopDisk/Acknowledgements.txt 與 $LICENSE_FILE 不一致（升級 Sparkle 後要更新，做法見 internal/release-process.md）"
fi

# 2. Sparkle 金鑰
PLIST_KEY=$(plutil -extract SUPublicEDKey raw Config/Info.plist)
KEYCHAIN_KEY=$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p 2>/dev/null) || KEYCHAIN_KEY=""
if [[ -z "$KEYCHAIN_KEY" ]]; then
    bad "登入鑰匙圈裡沒有 Sparkle 私鑰（換了電腦？用 generate_keys -f <備份檔> 匯入）"
elif [[ "$KEYCHAIN_KEY" != "$PLIST_KEY" ]]; then
    bad "鑰匙圈的 Sparkle 金鑰（$KEYCHAIN_KEY）和 Config/Info.plist 的 SUPublicEDKey 不同"
else
    ok "Sparkle 私鑰與 App 內的公鑰配對"
fi
fi

# 3. 要公開的檔案：檢查的是 export-public.sh 匯出的內容（和實際同步出去的一樣），所以只看 commit 過的檔案
EXPORT_DIR=$(mktemp -d)
trap 'rm -rf "$EXPORT_DIR"' EXIT
scripts/export-public.sh "$COMMIT" "$EXPORT_DIR"
[[ -n "$(git status --porcelain)" ]] && echo "  （工作目錄有還沒 commit 的修改，不在檢查範圍內）"

if [[ -e "$EXPORT_DIR/internal" || -e "$EXPORT_DIR/CLAUDE.md" ]]; then
    bad "匯出的內容含有 internal/ 或 CLAUDE.md（export-public.sh 的排除失效）"
fi

# App「關於」頁顯示的授權全文要和 repo 的 LICENSE 一字不差
if cmp -s "$EXPORT_DIR/LICENSE" "$EXPORT_DIR/PopDisk/License.txt"; then
    ok "App 內的授權全文（PopDisk/License.txt）與 LICENSE 相同"
else
    bad "PopDisk/License.txt 與 LICENSE 不同（改了授權後要複製一份過去：cp LICENSE PopDisk/License.txt）"
fi

# 繁中介面顯示的參考譯文要和 LICENSE.zh-Hant.md 兩條 --- 之間的譯文段落相同
if python3 - "$EXPORT_DIR/LICENSE.zh-Hant.md" "$EXPORT_DIR/PopDisk/License.zh-Hant.txt" <<'PY'
import sys
md = open(sys.argv[1], encoding='utf-8').read().split('\n---\n')
txt = open(sys.argv[2], encoding='utf-8').read()
sys.exit(0 if len(md) >= 3 and md[1].strip('\n') == txt.strip('\n') else 1)
PY
then
    ok "App 內的繁中參考譯文（PopDisk/License.zh-Hant.txt）與 LICENSE.zh-Hant.md 相同"
else
    bad "PopDisk/License.zh-Hant.txt 與 LICENSE.zh-Hant.md 的譯文段落（兩條 --- 之間）不同"
fi

# README 要完整揭露第三方授權：標記之間的全文要和 App 內的致謝（開頭 6 行是標題）一字不差，升級 Sparkle 時才不會只改到一份
if python3 - "$EXPORT_DIR/README.md" "$EXPORT_DIR/PopDisk/Acknowledgements.txt" <<'PY'
import re, sys
readme = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'<!-- BEGIN THIRD-PARTY LICENSES.*?-->\s*```text\n(.*?)\n```\s*<!-- END THIRD-PARTY LICENSES -->', readme, re.S)
ack = '\n'.join(open(sys.argv[2], encoding='utf-8').read().split('\n')[6:])
sys.exit(0 if m and m.group(1).strip('\n') == ack.strip('\n') else 1)
PY
then
    ok "README 的第三方授權全文與 PopDisk/Acknowledgements.txt 相同"
else
    bad "README 的第三方授權全文（BEGIN／END THIRD-PARTY LICENSES 之間）與 PopDisk/Acknowledgements.txt 不同，或找不到標記"
fi

DENYLIST=$(grep -v '^#' internal/public-denylist.txt | grep -v '^$')
if hits=$(cd "$EXPORT_DIR" && grep -rniF -f <(print -r -- "$DENYLIST") .); then
    bad "要公開的檔案含有私人資訊："
    print -r -- "$hits" | sed 's/^/      /' >&2
else
    ok "要公開的檔案沒有 public-denylist.txt 裡的字"
fi

# 公開 repo 沒有 internal/、CLAUDE.md，連過去的連結會壞掉（只提到名稱可以，連結不行）
if hits=$(cd "$EXPORT_DIR" && grep -rnE --include='*.md' '\]\([^)]*(internal/|CLAUDE\.md|TODO\.md)' .); then
    bad "要公開的文件連到不公開的檔案："
    print -r -- "$hits" | sed 's/^/      /' >&2
else
    ok "要公開的文件沒有連到 internal/ 或 CLAUDE.md"
fi

if (( failed )); then
    echo "==> 檢查沒有通過" >&2
    exit 1
fi
