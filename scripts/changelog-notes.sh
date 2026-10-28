#!/bin/zsh
# 印出 CHANGELOG.md 裡某個版本的段落（不含標題），給 appcast 與 Release 說明共用
#
# 用法：scripts/changelog-notes.sh <版本> [CHANGELOG 檔案]
#   CHANGELOG 檔案預設是 CHANGELOG.md；sync-public-repo.sh 發佈時傳入建置用 commit 的版本
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:?用法：scripts/changelog-notes.sh <版本> [CHANGELOG 檔案]}
FILE=${2:-CHANGELOG.md}

awk -v ver="$VERSION" '
    index($0, "## [" ver "]") == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
' "$FILE" | sed -e '/./,$!d'   # 去掉開頭的空行
