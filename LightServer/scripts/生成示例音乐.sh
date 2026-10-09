#!/bin/zsh
# 重新生成示例音乐：编译 scripts/生成示例音乐（发布模式），输出到仓库的 Resources/示例音乐。
set -euo pipefail
repo="${0:A:h:h}"
cd "$repo/scripts/生成示例音乐"
swift build -c release
"$(swift build -c release --show-bin-path)/生成示例音乐" "$repo/Resources/示例音乐"
