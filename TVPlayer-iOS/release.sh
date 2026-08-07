#!/bin/bash
# 一键发布脚本 - 在 TVPlayer-iOS 目录下运行
# 用法: ./release.sh v2.3.8-ios   (tag 必须以 -ios 结尾才能触发 CI 的 build-ios.yml)

set -e

VERSION=$1
if [ -z "$VERSION" ]; then
    echo "用法: ./release.sh v2.3.8-ios"
    exit 1
fi

# CI 的 build-ios.yml 只在 v*-ios 的 tag push 时启动；缺 -ios 后缀会静默无产物。
if [[ "$VERSION" != *-ios ]]; then
    echo "错误: tag 必须以 -ios 结尾（CI 触发规则），例如 ./release.sh v2.3.8-ios"
    exit 1
fi

echo "=== 发布 TVPlayer iOS $VERSION ==="

# 确保在 git 仓库中
if [ ! -d .git ]; then
    echo "错误: 当前目录不是 git 仓库"
    exit 1
fi

# 检查是否有未提交的变更
if ! git diff-index --quiet HEAD --; then
    echo "提交本地变更..."
    git add .
    git commit -m "release: $VERSION"
fi

# 推送代码
echo "推送代码..."
git push origin main

# 创建并推送 tag（不强制覆盖：若 tag 已存在则报错退出，避免覆盖线上历史）
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
    echo "错误: tag '$VERSION' 已存在。如需重新发布请先删除或使用新版本号。"
    exit 1
fi
echo "创建 tag: $VERSION"
git tag "$VERSION"
git push origin "$VERSION"

echo ""
echo "=== Tag 已推送，等待 GitHub Actions 构建完成 ==="
echo ""
echo "接下来请手动操作:"
echo "1. 打开 GitHub 仓库 Releases 页面"
echo "2. 找到 '$VERSION' tag 对应的 Release（Actions 构建完成后自动生成）"
echo "3. 编辑 Release 内容，粘贴发布说明"
echo "4. 上传 TVPlayer.ipa 文件"
echo "5. 发布"
echo ""
echo "或者使用 GitHub CLI (gh) 自动创建 Release:"
echo "gh release create $VERSION --title \"TVPlayer iOS $VERSION\" --notes-file RELEASE_NOTES.md"
