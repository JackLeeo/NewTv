# TVBox Flutter - Node.js Mobile 构建指南

## 概述

本目录包含用于iOS应用Node.js运行时的完整构建系统。

## 目录结构

```
nodejs-project/
├── src/                    # 源代码
│   ├── spider/            # 视频源爬虫
│   ├── util/             # 工具函数
│   ├── website/          # React配置界面
│   ├── index.js          # 主入口
│   ├── index.config.js   # 配置文件
│   ├── dev.js            # 开发环境入口
│   └── router.js         # API路由
├── dist/                  # 构建输出目录
├── node_modules/          # npm依赖
├── build.js              # 构建脚本
├── build-optimized.js    # 优化版构建脚本
├── build.sh             # Shell构建脚本
├── package.json          # npm配置
└── README.md            # 本文档
```

## 快速开始

### 方式1: 使用构建脚本（推荐）

```bash
# 进入目录
cd ios/Runner/nodejs-project

# 运行构建
./build.sh
```

### 方式2: 手动构建

```bash
# 1. 安装依赖
npm install

# 2. 运行构建
npm run build

# 或开发模式
npm run build:dev
```

## 依赖说明

### 核心依赖（必须）
- `fastify` - Web服务器框架
- `node-json-db` - JSON数据库
- `axios` - HTTP客户端

### 爬虫依赖
- `cheerio` - HTML解析
- `crypto-js` - 加密工具
- `iconv-lite` - 编码转换
- `hls-parser` - M3U8解析

### 网盘依赖
- `node-rsa` - RSA加密

### 配置界面依赖（可选）
- `react` / `react-dom`
- `antd`
- `qrcode`
- `dayjs`
- `less`

## 构建产物

构建完成后，`dist/`目录包含：

- `index.js` - 主程序（含website bundle）
- `index.js.md5` - MD5校验码
- `index.config.js` - 配置文件
- `index.config.js.md5` - 配置MD5校验码

## iOS集成

### 自动集成

Xcode构建时，会自动复制`dist/`到Bundle：

1. 构建项目
2. 构建产物自动包含在应用的Resources中

### 手动集成

如需手动集成：

1. 构建Node.js代码
2. 复制`dist/`到`ios/Runner/`
3. 确保Xcode的Build Phases包含这些文件

## 调试

### 查看日志

应用启动后，通过日志查看器查看Node.js日志：

1. 点击首页右上角📋图标
2. 查看控制台输出

### 常见问题

1. **Node.js启动失败**
   - 检查NodeMobile.framework是否正确链接
   - 查看Xcode控制台错误信息

2. **端口冲突**
   - 确保没有其他应用占用端口

3. **模块加载失败**
   - 检查npm依赖是否完整安装
   - 确认node_modules在正确位置

## 开发

### 开发模式

```bash
# 监控文件变化自动重载
nodemon --config nodemon.json
```

### 添加新的Spider

1. 在`src/spider/`创建新文件
2. 在`src/router.js`注册路由
3. 重新构建

## 构建优化

### 减小体积

```javascript
// build.js中启用minify
const isDev = false; // 生产模式自动压缩
```

### 移除调试代码

```javascript
// 生产环境自动移除console.log
```

## 技术栈

- **运行时**: Node.js Mobile 18.x (iOS)
- **服务器**: Fastify 4.x
- **构建**: esbuild 0.20
- **配置界面**: React 18 + Ant Design 5

## 许可

MIT License
