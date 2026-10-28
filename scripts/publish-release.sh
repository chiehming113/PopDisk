#!/bin/zsh
# 公開發佈 release.sh 做好的版本，並在私有 repo 留一份備份
#
# 用法：scripts/publish-release.sh [--dry-run] <版本>
#   --dry-run  只檢查並印出會執行的步驟，不改動任何東西
#
# 步驟（任何一步失敗就停止；重新執行會跳過已完成的步驟）：
#   1. 私有 repo（chiehming113/pop-disk）建立 Release v<版本> 當備份：tag 打在建置用的 commit，
#      附上 zip、dSYM、這一版的 appcast.xml
#   2. 把建置用 commit 的原始碼同步到公開 repo（chiehming113/PopDisk）：一個「PopDisk <版本>」commit，不含 appcast
#   3. 公開 repo 建立 Release v<版本>，tag 打在第 2 步的 commit（含這一版的原始碼），上傳 zip
#   4. 推送 appcast（scripts/sync-public-repo.sh --appcast）：使用者從這一刻起才會收到更新
# 先上傳 zip 再推 appcast，否則使用者會看到新版卻下載不到。說明一律取自 CHANGELOG。
set -euo pipefail
cd "${0:A:h}/.."

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi
VERSION=${1:?用法：scripts/publish-release.sh [--dry-run] <版本>}

PRIVATE_REPO=chiehming113/pop-disk
PUBLIC_REPO=chiehming113/PopDisk
OUT=build/release
ZIP="$OUT/PopDisk-$VERSION.zip"
DSYMS="$OUT/PopDisk-$VERSION-dSYMs.zip"
COMMIT_FILE="$OUT/PopDisk-$VERSION.commit"
APPCAST=build/public-repo/appcast.xml
TAG="v$VERSION"
# 0.x 是測試版：公開 Release 標成 Pre-release，Releases 頁才看得出不是穩定版本（Sparkle 不看這個標記，一樣會更新）
PRERELEASE=()
[[ "$VERSION" == 0.* || "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)

fail() { echo "$1" >&2; exit 1; }
run() {
    print -r -- "    \$ ${(q-)@}"
    $DRY_RUN || "$@"
}

# ---- 檢查 ----
for file in "$ZIP" "$DSYMS" "$COMMIT_FILE"; do
    [[ -f "$file" ]] || fail "找不到 $file，請先執行 scripts/release.sh"
done
COMMIT=$(<"$COMMIT_FILE")
git cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "找不到建置用的 commit $COMMIT"
# tag 要打在 GitHub 上看得到的 commit
git fetch --quiet origin
git merge-base --is-ancestor "$COMMIT" origin/main || fail "建置用的 commit $COMMIT 還沒推到 GitHub"

grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
    || fail "$APPCAST 裡沒有 $VERSION（release.sh 之後被還原了？可以重跑 scripts/appcast.sh $ZIP $APPCAST）"

NOTES=$(scripts/changelog-notes.sh "$VERSION")
[[ -n "$NOTES" ]] || fail "CHANGELOG.md 沒有 ## [$VERSION] 的段落，請先把「未發佈」移到這個版本下"

# 私有 repo 的同名舊 Release（例如 10/26 的沙盒版草稿）不自動刪除，請本人確認後處理
private_state=$(gh release view "$TAG" --repo "$PRIVATE_REPO" --json isDraft -q 'if .isDraft then "draft" else "published" end' 2>/dev/null) || private_state=none
[[ "$private_state" == "draft" ]] && fail "私有 repo 已有 $TAG 的草稿（舊版），請確認後刪除：gh release delete $TAG --repo $PRIVATE_REPO"
public_state=$(gh release view "$TAG" --repo "$PUBLIC_REPO" --json isDraft -q 'if .isDraft then "draft" else "published" end' 2>/dev/null) || public_state=none
[[ "$public_state" == "draft" ]] && fail "公開 repo 已有 $TAG 的草稿，請確認後刪除：gh release delete $TAG --repo $PUBLIC_REPO"

PUBLIC_URL="https://github.com/$PUBLIC_REPO/releases/tag/$TAG"
echo "==> 要發佈 PopDisk $VERSION（原始碼 ${COMMIT:0:7}）"
if ! $DRY_RUN; then
    read -q "?確定要公開發佈嗎？[y/N] " || { echo; fail "已取消"; }
    echo
fi

notes_file=$(mktemp)
backup_notes=$(mktemp)
appcast_dir=$(mktemp -d)
appcast_copy=$appcast_dir/appcast.xml
trap 'rm -rf "$notes_file" "$backup_notes" "$appcast_dir"' EXIT
print -r -- "$NOTES" > "$notes_file"
cp "$APPCAST" "$appcast_copy"
{
    print -r -- "$NOTES"
    print
    print -r -- "---"
    print -r -- "備份：公開版 $PUBLIC_URL"
    print -r -- "原始碼：$COMMIT"
    print -r -- "附件：App（與公開版相同）、dSYM（對照當機紀錄用）、發佈當下的 appcast.xml"
    print -r -- "公開 repo 的原始碼：v$VERSION tag 指向的「PopDisk $VERSION」commit（內容是上面這個 commit 的檔案，不含 internal/、CLAUDE.md）"
} > "$backup_notes"

# ---- 1. 私有 repo 備份 ----
if [[ "$private_state" == "published" ]]; then
    echo "==> 1/4 私有 repo 已有 $TAG，略過"
else
    echo "==> 1/4 私有 repo 建立備份 Release"
    run gh release create "$TAG" "$ZIP" "$DSYMS" "$appcast_copy" --repo "$PRIVATE_REPO" \
        --target "$COMMIT" --title "PopDisk $VERSION" --notes-file "$backup_notes"
fi

# ---- 2 + 3. 公開 repo：原始碼，再建立 Release ----
if [[ "$public_state" == "published" ]]; then
    echo "==> 2/4、3/4 公開 repo 已有 $TAG，略過"
else
    # 重跑時（例如上次第 3 步失敗）這一步沒有變更，公開 repo 的 HEAD 仍是上次推的「PopDisk $VERSION」
    echo "==> 2/4 同步這一版的原始碼到公開 repo（appcast 留到最後）"
    run scripts/sync-public-repo.sh --release "$COMMIT" "$VERSION" --no-appcast --push
    if $DRY_RUN; then
        PUBLIC_COMMIT="<第 2 步推上去的 commit>"
        PUBLIC_SHORT=$PUBLIC_COMMIT
    else
        PUBLIC_COMMIT=$(git -C build/public-repo rev-parse HEAD)
        [[ "$(git -C build/public-repo log -1 --format=%s "$PUBLIC_COMMIT")" == "PopDisk $VERSION" ]] \
            || fail "公開 repo 的 HEAD 不是「PopDisk $VERSION」，tag 不知道該打在哪裡，請確認 build/public-repo"
        PUBLIC_SHORT=${PUBLIC_COMMIT:0:7}
    fi
    echo "==> 3/4 公開 repo 建立 Release（tag 打在 $PUBLIC_SHORT）"
    run gh release create "$TAG" "$ZIP" --repo "$PUBLIC_REPO" "${PRERELEASE[@]}" \
        --target "$PUBLIC_COMMIT" --title "PopDisk $VERSION" --notes-file "$notes_file"
fi

# ---- 4. 推 appcast ----
echo "==> 4/4 推送 appcast"
run scripts/sync-public-repo.sh --appcast "$VERSION" --push

if $DRY_RUN; then
    echo "==> dry run：沒有改動任何東西"
else
    echo "==> 完成：$PUBLIC_URL"
fi
