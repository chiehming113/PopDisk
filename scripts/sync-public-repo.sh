#!/bin/zsh
# 把要公開的檔案同步到公開 repo（github.com/chiehming113/PopDisk）
#
# 用法：
#   scripts/sync-public-repo.sh [--no-appcast] [--push]
#       文件模式（預設）：兩次發佈之間只更新文件與 appcast（README、CHANGELOG、CONTRIBUTING、LICENSE*、PRIVACY*、
#       截圖、問題回報範本），來源是 HEAD。公開 repo 裡上一版的原始碼不會被動到
#   scripts/sync-public-repo.sh --release <commit> <版本> [--no-appcast] [--push]
#       發佈模式（publish-release.sh 用）：把建置用 commit 的整份內容（scripts/export-public.sh）同步過去，
#       commit 訊息是「PopDisk <版本>」加上 CHANGELOG 該版段落
#   scripts/sync-public-repo.sh --appcast <版本> [--push]
#       只推 appcast.xml（publish-release.sh 最後一步，zip 上傳之後使用者才看到新版）
#   --no-appcast  不把 appcast.xml 的修改放進這個 commit（release.sh 加進去、還沒公開的新版本留在工作 clone）
#   --push        commit 並 push；不加的話只更新 build/public-repo 並顯示差異
#
# 原則（見 internal/open-source-plan.md）：
# - 本 repo 是唯一的來源，不要直接在公開 repo 上修改，下次同步會被蓋掉
# - 原始碼只在發佈時同步。公開 repo 的歷史只由這個腳本產生，一次發佈一個 commit
# - 只複製檔案（git archive），不用 git log、format-patch、cherry-pick，也不把本 repo 的分支推過去：
#   本 repo 的 commit 說明、作者、時間都不能出現在公開 repo
# - 公開 repo 的作者固定是 MingTW <popdisk@chorgi.cc>，不能用私人信箱
set -euo pipefail
cd "${0:A:h}/.."

REPO=chiehming113/PopDisk
DIR=${PUBLIC_REPO_DIR:-build/public-repo}
AUTHOR_NAME=MingTW
AUTHOR_EMAIL=popdisk@chorgi.cc
# 公開 repo 上允許出現的 commit 標題（這個腳本產生的格式，加上 2026-10-27 的舊格式「Sync from pop-disk@…」）
ALLOWED_SUBJECTS='^(Sync from pop-disk@[0-9a-f]+|PopDisk [0-9][^ ]*|Publish PopDisk [0-9][^ ]* to the update feed|Update public documents|Update the update feed)$'

fail() { echo "$1" >&2; exit 1; }

MODE=docs
SOURCE=HEAD
VERSION=""
NO_APPCAST=false
PUSH=false
while (( $# )); do
    case "$1" in
        --release) MODE=release; SOURCE=${2:?--release 要接 commit 與版本}; VERSION=${3:?--release 要接 commit 與版本}; shift 3 ;;
        --appcast) MODE=appcast; VERSION=${2:?--appcast 要接版本}; shift 2 ;;
        --no-appcast) NO_APPCAST=true; shift ;;
        --push) PUSH=true; shift ;;
        *) fail "不認得的參數：$1" ;;
    esac
done
SOURCE_SHORT=$(git rev-parse --short "$SOURCE^{commit}")

# 公開出去就收不回來，先擋掉私人資訊（檢查的是要同步的那個 commit）
[[ "$MODE" != appcast ]] && scripts/preflight.sh --public-only "$SOURCE"

if [[ ! -d "$DIR/.git" ]]; then
    rm -rf "$DIR"
    if [[ -n "${PUBLIC_REPO_URL:-}" ]]; then
        git clone --quiet "$PUBLIC_REPO_URL" "$DIR"   # 測試用：指向本機的模擬 repo
    else
        gh repo clone "$REPO" "$DIR" -- --quiet
    fi
    # 剛建立的空 repo 沒有任何分支，先指定 main
    git -C "$DIR" symbolic-ref HEAD refs/heads/main
fi
# appcast.xml 可能有 release.sh 剛加、還沒推的版本，不能用 reset 蓋掉
if git -C "$DIR" rev-parse --verify --quiet '@{u}' >/dev/null; then
    git -C "$DIR" pull --quiet --rebase --autostash
fi

# 公開 repo 的作者：每次都設定，再確認實際會用的身分（環境變數 GIT_AUTHOR_* 也可能蓋過設定）
git -C "$DIR" config user.name "$AUTHOR_NAME"
git -C "$DIR" config user.email "$AUTHOR_EMAIL"
for ident in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
    [[ "$(git -C "$DIR" var "$ident")" == "$AUTHOR_NAME <$AUTHOR_EMAIL> "* ]] \
        || fail "公開 repo 的 commit 身分不是 $AUTHOR_NAME <$AUTHOR_EMAIL>（$ident = $(git -C "$DIR" var "$ident")），停止"
done

# 公開 repo 上有不是這個腳本推的 commit（例如有人在網頁上改了檔案）時停下來，否則下面的 --delete 會把它蓋掉
if git -C "$DIR" rev-parse --verify --quiet HEAD >/dev/null; then
    if others=$(git -C "$DIR" log --format='%h %s' | grep -vE "^[0-9a-f]+ ${ALLOWED_SUBJECTS#^}"); then
        fail "公開 repo 有不是同步腳本推的 commit，請先確認並把修改搬回本 repo：
$others"
    fi
fi

EXPORT_DIR=$(mktemp -d)
MESSAGE_FILE=$(mktemp)
trap 'rm -rf "$EXPORT_DIR" "$MESSAGE_FILE"' EXIT

case "$MODE" in
    release)
        scripts/export-public.sh "$SOURCE" "$EXPORT_DIR"
        # 整份換成這一版的內容；appcast.xml 是公開 repo 自己的檔案，不覆蓋也不刪除
        rsync -a --delete --exclude=.git --exclude=appcast.xml "$EXPORT_DIR/" "$DIR/"
        ;;
    docs)
        scripts/export-public.sh --docs-only "$SOURCE" "$EXPORT_DIR"
        # 只動固定清單內的路徑（和 export-public.sh 的 --docs-only 相同），公開 repo 裡上一版的原始碼不能刪。
        # 要逐一處理到這個層級：對整個 assets/ 做 --delete 會刪掉發佈時放上去的 assets/icon/ 等
        for p in README.md CHANGELOG.md CONTRIBUTING.md LICENSE LICENSE.zh-Hant.md PRIVACY.md PRIVACY.zh-Hant.md \
                 assets/screenshots .github; do
            [[ -e "$EXPORT_DIR/$p" ]] || continue
            mkdir -p "$DIR/${p:h}"
            if [[ -d "$EXPORT_DIR/$p" ]]; then
                rsync -a --delete "$EXPORT_DIR/$p/" "$DIR/$p/"
            else
                cp "$EXPORT_DIR/$p" "$DIR/$p"
            fi
        done
        ;;
esac

# 第一次建立時放一個空的 appcast（只有 channel），之後由 scripts/appcast.sh 加入版本
if [[ ! -f "$DIR/appcast.xml" ]]; then
    cat > "$DIR/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PopDisk</title>
    <link>https://github.com/chiehming113/PopDisk</link>
  </channel>
</rss>
XML
fi

case "$MODE" in
    appcast) git -C "$DIR" add -- appcast.xml ;;
    *)
        git -C "$DIR" add -A
        $NO_APPCAST && git -C "$DIR" reset --quiet -- appcast.xml
        ;;
esac

if git -C "$DIR" diff --cached --quiet; then
    git -C "$DIR" reset --quiet
    echo "==> 公開 repo 已是最新"
    exit 0
fi
git -C "$DIR" diff --cached --stat

# commit 訊息只寫給使用者看的內容，不引用本 repo 的 commit 說明
case "$MODE" in
    release)
        notes=$(scripts/changelog-notes.sh "$VERSION" "$EXPORT_DIR/CHANGELOG.md")
        [[ -n "$notes" ]] || fail "建置用 commit 的 CHANGELOG.md 沒有 ## [$VERSION] 的段落"
        print -r -- "PopDisk $VERSION

$notes

Source: pop-disk@$SOURCE_SHORT" > "$MESSAGE_FILE"
        ;;
    appcast)
        print -r -- "Publish PopDisk $VERSION to the update feed" > "$MESSAGE_FILE"
        ;;
    docs)
        if [[ "$(git -C "$DIR" diff --cached --name-only)" == appcast.xml ]]; then
            print -r -- "Update the update feed" > "$MESSAGE_FILE"
        else
            {
                print -r -- "Update public documents"
                print
                git -C "$DIR" diff --cached --stat
            } > "$MESSAGE_FILE"
        fi
        ;;
esac
DENYLIST=$(grep -v '^#' internal/public-denylist.txt | grep -v '^$')
if hits=$(grep -niF -f <(print -r -- "$DENYLIST") "$MESSAGE_FILE"); then
    fail "commit 訊息含有私人資訊：
$hits"
fi

if ! $PUSH; then
    git -C "$DIR" reset --quiet
    echo "==> 以上是待同步的變更（在 $DIR）；commit 訊息會是："
    sed 's/^/    /' "$MESSAGE_FILE"
    echo "==> 確認後加上 --push 推上去"
    exit 0
fi

git -C "$DIR" commit --quiet -F "$MESSAGE_FILE"
git -C "$DIR" push --quiet -u origin main
echo "==> 已推到 https://github.com/$REPO（$(git -C "$DIR" rev-parse --short HEAD)）"
