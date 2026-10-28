#!/bin/zsh
# 把一個已壓縮的版本加進 Sparkle 的 appcast（放在最上面）
#
# 用法：scripts/appcast.sh [--url-prefix <網址>] <PopDisk-版本.zip> <appcast.xml>
#   --url-prefix  zip 的下載位置（不含檔名）；預設是公開 repo 這個版本的 Release
#                 測試時改成本機，例如 http://127.0.0.1:8765
#
# 簽章用 Sparkle 的 sign_update，私鑰從登入鑰匙圈讀取（generate_keys 產生的那一把）。
# appcast.xml 不存在時會建立一個空的。
set -euo pipefail
cd "${0:A:h}/.."

URL_PREFIX=""
if [[ "${1:-}" == "--url-prefix" ]]; then
    URL_PREFIX=${2:?缺少 --url-prefix 的網址}
    shift 2
fi
ZIP=${1:?用法：scripts/appcast.sh [--url-prefix <網址>] <zip> <appcast.xml>}
APPCAST=${2:?用法：scripts/appcast.sh [--url-prefix <網址>] <zip> <appcast.xml>}

SIGN_UPDATE=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "找不到 $SIGN_UPDATE，請先用 -clonedSourcePackagesDirPath build/SourcePackages 建置一次" >&2
    exit 1
fi

# 版本資訊從 zip 裡的 App 讀，避免和實際內容對不上
plist=$(mktemp)
trap 'rm -f "$plist"' EXIT
unzip -p "$ZIP" 'PopDisk.app/Contents/Info.plist' > "$plist"
BUILD=$(plutil -extract CFBundleVersion raw "$plist")
VERSION=$(plutil -extract CFBundleShortVersionString raw "$plist")
MIN_SYSTEM=$(plutil -extract LSMinimumSystemVersion raw "$plist")

if [[ -z "$URL_PREFIX" ]]; then
    URL_PREFIX="https://github.com/chiehming113/PopDisk/releases/download/v$VERSION"
fi

# 輸出像 sparkle:edSignature="..." length="..."
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")

# 更新說明：CHANGELOG 裡這個版本的段落（Sparkle 會顯示成 Markdown）
NOTES=$(scripts/changelog-notes.sh "$VERSION")

python3 - "$APPCAST" "$VERSION" "$BUILD" "$MIN_SYSTEM" "$URL_PREFIX/${ZIP:t}" "$SIGNATURE" "$NOTES" <<'PY'
import sys, os, re
from email.utils import formatdate

path, version, build, min_system, url, signature, notes = sys.argv[1:]
if not os.path.exists(path):
    open(path, "w").write("""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PopDisk</title>
    <link>https://github.com/chiehming113/PopDisk</link>
  </channel>
</rss>
""")
xml = open(path).read()
if re.search(r"<sparkle:version>%s</sparkle:version>" % re.escape(build), xml):
    sys.exit(f"appcast 裡已經有 build {build}，請先修改 CURRENT_PROJECT_VERSION")

item = f"""    <item>
      <title>PopDisk {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{notes.strip()}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature.strip()}/>
    </item>
"""
# 新版放最上面：插在第一個 <item> 前，沒有的話插在 </channel> 前
anchor = xml.find("    <item>")
if anchor < 0:
    anchor = xml.find("  </channel>")
xml = xml[:anchor] + item + xml[anchor:]
open(path, "w").write(xml)
print(f"==> 已加入 PopDisk {version} ({build}) → {path}")
PY
