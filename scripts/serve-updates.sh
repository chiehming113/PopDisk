#!/bin/zsh
# 測試 App 內更新用：在本機提供 appcast.xml 與 zip
#
# 用法：scripts/serve-updates.sh [--slow] <資料夾>
#   --slow  appcast.xml 延遲 5 秒才回應。Sparkle 在更新器啟動 3 秒內找到新版會直接跳出視窗，
#           要測背景提醒（選單底部的「安裝…」與通知）就要讓它晚一點才找到
# 再用 Debug 版的 -updateFeedURL http://127.0.0.1:8765/appcast.xml 啟動 PopDisk（見 internal/release-process.md）
set -euo pipefail
DELAY=0
if [[ "${1:-}" == "--slow" ]]; then
    DELAY=5
    shift
fi
DIR=${1:?用法：scripts/serve-updates.sh [--slow] <放 appcast.xml 與 zip 的資料夾>}
echo "==> http://127.0.0.1:8765/appcast.xml（appcast 延遲 ${DELAY} 秒；Ctrl-C 結束）"
# 只聽 127.0.0.1，不讓區網其他機器連進來
exec python3 - "$DIR" "$DELAY" <<'PY'
import functools, http.server, sys, time
directory, delay = sys.argv[1], float(sys.argv[2])

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/appcast.xml"):
            time.sleep(delay)
        super().do_GET()

http.server.ThreadingHTTPServer(("127.0.0.1", 8765), functools.partial(Handler, directory=directory)).serve_forever()
PY
