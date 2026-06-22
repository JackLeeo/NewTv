# TVBox Node.js Mobile 构建脚本 (Windows PowerShell)
# 使用方法: 右键 -> 使用PowerShell运行

Write-Host "🚀 TVBox Node.js Mobile 构建系统" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

# 获取脚本目录
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# 检查Node.js
try {
    $nodeVersion = node --version
    Write-Host "✅ Node.js: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ 错误: Node.js 未安装或未配置到PATH" -ForegroundColor Red
    Write-Host "请从 https://nodejs.org 下载安装 Node.js 18+" -ForegroundColor Yellow
    Read-Host "按Enter键退出"
    exit 1
}

# 检查npm
try {
    $npmVersion = npm --version
    Write-Host "✅ npm: $npmVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ 错误: npm 未安装" -ForegroundColor Red
    Read-Host "按Enter键退出"
    exit 1
}

# 创建dist目录
$distDir = Join-Path $scriptDir "dist"
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    Write-Host "📁 创建输出目录: dist/" -ForegroundColor Cyan
}

# 检查node_modules
$nodeModulesDir = Join-Path $scriptDir "node_modules"
if (-not (Test-Path $nodeModulesDir)) {
    Write-Host "`n📦 正在安装npm依赖..." -ForegroundColor Yellow
    Write-Host "   (首次安装可能需要几分钟)`n" -ForegroundColor Gray

    npm install --legacy-peer-deps

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ npm install 失败" -ForegroundColor Red
        Read-Host "按Enter键退出"
        exit 1
    }
    Write-Host "✅ npm依赖安装完成`n" -ForegroundColor Green
} else {
    Write-Host "✅ npm依赖已安装" -ForegroundColor Green
}

# 检查关键依赖
Write-Host "`n🔍 检查关键依赖..." -ForegroundColor Cyan

$requiredPackages = @("esbuild", "less", "fastify")
foreach ($pkg in $requiredPackages) {
    $pkgPath = Join-Path $nodeModulesDir $pkg
    if (Test-Path $pkgPath) {
        Write-Host "   ✅ $pkg" -ForegroundColor Green
    } else {
        Write-Host "   ⚠️  $pkg 未找到，正在安装..." -ForegroundColor Yellow
        npm install $pkg --save
    }
}

# 开始构建
Write-Host "`n🔨 开始构建..." -ForegroundColor Yellow

# 设置环境变量
$env:NODE_ENV = "production"

# 运行构建
try {
    node build-optimized.js

    if ($LASTEXITCODE -ne 0) {
        throw "构建脚本返回错误码: $LASTEXITCODE"
    }

    Write-Host "`n✅ 构建成功！" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`n📦 构建产物位于: dist/" -ForegroundColor Cyan
    Write-Host "`n构建产物:" -ForegroundColor White
    Write-Host "   - main.js (主程序)" -ForegroundColor Gray
    Write-Host "   - index.config.js (配置)" -ForegroundColor Gray
    Write-Host "   - *.md5 (校验文件)" -ForegroundColor Gray

    # 显示文件大小
    $mainJs = Join-Path $distDir "main.js"
    if (Test-Path $mainJs) {
        $size = (Get-Item $mainJs).Length / 1KB
        Write-Host "`n📊 主程序大小: $([math]::Round($size, 2)) KB" -ForegroundColor Cyan
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "🎉 构建完成！" -ForegroundColor Green
    Write-Host "`n下一步:" -ForegroundColor Yellow
    Write-Host "1. Xcode会自动在构建时复制dist/到Bundle" -ForegroundColor White
    Write-Host "2. 或手动复制dist/到ios/Runner/Resources/" -ForegroundColor White
    Write-Host "3. 重新编译iOS应用`n" -ForegroundColor White

} catch {
    Write-Host "`n❌ 构建失败: $_" -ForegroundColor Red
    Write-Host "`n调试提示:" -ForegroundColor Yellow
    Write-Host "- 检查Node.js依赖是否完整" -ForegroundColor White
    Write-Host "- 查看上方错误信息" -ForegroundColor White
    Write-Host "- 检查源代码是否有语法错误`n" -ForegroundColor White
}

Read-Host "按Enter键退出"
