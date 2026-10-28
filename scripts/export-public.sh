#!/bin/zsh
# 把要放到公開 repo 的檔案匯出到指定資料夾（preflight.sh 與 sync-public-repo.sh 共用，兩邊檢查與同步的才會是同一份內容）
#
# 用法：scripts/export-public.sh <commit> <輸出資料夾>
#   --docs-only  只匯出兩次發佈之間可以單獨更新的文件（見 internal/open-source-plan.md 第 3 節）
#
# 用 git archive 而不是複製工作目錄：只會帶到 commit 過的檔案，未追蹤的檔案、build/ 不會跟著出去；
# 也不含任何 commit 物件，私有 repo 的 commit 說明與作者不會外流。
# internal/、CLAUDE.md 永遠不公開；public-repo/.github/ 放到公開 repo 的 .github/。
set -euo pipefail
cd "${0:A:h}/.."

DOCS_ONLY=false
if [[ "${1:-}" == "--docs-only" ]]; then
    DOCS_ONLY=true
    shift
fi
COMMIT=${1:?用法：scripts/export-public.sh [--docs-only] <commit> <輸出資料夾>}
OUT=${2:?用法：scripts/export-public.sh [--docs-only] <commit> <輸出資料夾>}

# 兩次發佈之間可以單獨更新的檔案；原始碼只在發佈時同步
DOCS_PATHS=(README.md CHANGELOG.md CONTRIBUTING.md LICENSE LICENSE.zh-Hant.md PRIVACY.md PRIVACY.zh-Hant.md assets/screenshots)

git rev-parse --verify --quiet "$COMMIT^{commit}" >/dev/null || { echo "找不到 commit：$COMMIT" >&2; exit 1; }
mkdir -p "$OUT"

if $DOCS_ONLY; then
    # 還沒有的檔案（例如 CONTRIBUTING.md 尚未建立）就略過
    paths=()
    for p in "${DOCS_PATHS[@]}"; do
        [[ -n "$(git ls-tree "$COMMIT" -- "$p")" ]] && paths+=("$p")
    done
else
    paths=(. ':(exclude)internal' ':(exclude)public-repo' ':(exclude)CLAUDE.md')
fi
git archive --format=tar "$COMMIT" -- "${paths[@]}" | tar -x -C "$OUT"

# 問題回報範本：私有 repo 的 public-repo/.github/ → 公開 repo 的 .github/
if [[ -n "$(git ls-tree "$COMMIT" -- public-repo/.github)" ]]; then
    git archive --format=tar "$COMMIT" -- public-repo/.github | tar -x -C "$OUT"
    rm -rf "$OUT/.github"
    mv "$OUT/public-repo/.github" "$OUT/.github"
    rm -rf "$OUT/public-repo"
fi
