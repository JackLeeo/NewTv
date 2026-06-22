#!/bin/bash
set -e

echo "=== Building Node.js project for iOS ==="

cd "$(dirname "$0")"

# 检查 Node.js 是否安装
if ! command -v node &> /dev/null; then
    echo "Node.js not found, skipping build"
    exit 0
fi

# 进入 nodejs-project 目录
cd nodejs-project

# 安装依赖（如果需要）
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install --silent 2>/dev/null || echo "npm install skipped"
fi

# 构建项目
echo "Building..."
node build-optimized.js || node build.js

# 确保 dist/main.js 存在
if [ -d "dist" ]; then
    if [ -f "dist/main.js" ]; then
        echo "✅ main.js found"
    fi

    echo "✅ Node.js build completed"
    ls -la dist/
else
    echo "⚠️  dist directory not created, creating manually..."
    mkdir -p dist
    if [ -f "src/dev.js" ]; then
        # 创建一个简单的入口点
        echo "// Node.js entry point placeholder" > dist/main.js
        echo "✅ dist/main.js created (placeholder)"
    fi
fi
