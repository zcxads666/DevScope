#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 部分 Command Line Tools 的 SwiftPM 没有自动加入自带测试框架的搜索路径。
developer_dir="$(xcode-select -p)"
framework_dir="$developer_dir/Library/Developer/Frameworks"
test_flags=(--disable-xctest --enable-swift-testing)
if [ -d "$framework_dir/Testing.framework" ]; then
    test_flags+=(
        -Xswiftc -F -Xswiftc "$framework_dir"
        -Xlinker -F -Xlinker "$framework_dir"
        -Xlinker -rpath -Xlinker "$framework_dir"
        -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
    )
fi
swift test "${test_flags[@]}" "$@"
