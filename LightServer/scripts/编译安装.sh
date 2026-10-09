#!/bin/zsh
# 编译 Release 版菜单栏应用（本机自签名），装到 /Applications/轻量音乐服务器.app。
# 已有同名应用时不覆盖、直接停下（由人决定怎么处理旧版）。只编译不安装：加参数 --no-install。
set -euo pipefail
repo="${0:A:h:h}"
target="/Applications/轻量音乐服务器.app"
install=1
[[ "${1:-}" == "--no-install" ]] && install=0
if (( install )) && [[ -e "$target" ]]; then
  echo "已经有 $target，没有覆盖。请先确认旧版怎么处理。" >&2
  exit 3
fi
cd "$repo/App"
xcodegen generate --quiet
xcodebuild -project LightMusicServer.xcodeproj -scheme LightMusicServerApp -configuration Release \
  -derivedDataPath "$repo/build/DerivedData" CODE_SIGN_IDENTITY=- build | grep -E "error|warning: |BUILD" || true
app="$repo/build/DerivedData/Build/Products/Release/轻量音乐服务器.app"
[[ -d "$app" ]] || { echo "没有编出应用" >&2; exit 1; }
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -E "Identifier|flags|Signature"
if (( install )); then
  ditto "$app" "$target"
  echo "已装到 $target"
fi
