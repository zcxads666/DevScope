# DevScope — 本地开发服务监控（macOS 菜单栏应用）

一个原生 SwiftUI 菜单栏应用，自动发现并健康检查本机运行的前端、后端、数据库与中间件，按下拉面板展示，自动适配系统深色 / 浅色主题。

## 功能

- **自动发现**：扫描本机 TCP 监听端口，读取进程命令行 / 工作目录，识别出对应服务
- **角色与技术栈**：区分 前端（Vite / Next.js / Nuxt / Webpack / Angular…）、后端（NestJS / Express / Go / Rust / Django / FastAPI / Spring Boot…）、数据库（PostgreSQL / MySQL / Redis / MongoDB…）、中间件（RabbitMQ / Kafka / Nginx…）
- **按项目聚合**：通过 `.git` / `package.json` / `go.mod` 等标记向上追溯项目根目录，同一项目的前后端自动归组；Docker 容器按 compose 项目归组
- **健康检查**：HTTP 服务每 10 秒探活（状态码 + 延迟），数据库 / 中间件做 TCP 探活
- **macOS 原生风格**：菜单栏下拉毛玻璃面板、连续圆角卡片、语义色自动适配深浅色
- **快捷操作**：一键在浏览器打开、复制地址、在 Finder 中定位项目

## 使用

```bash
./scripts/make-app.sh   # 构建 + 组装 .app
open build/DevScope.app # 启动，菜单栏出现 🗄 图标 + 服务数
```

点击菜单栏图标即可下拉查看面板；面板底部可手动退出。

命令行模式（不启动 GUI）：

```bash
.build/release/DevScope --scan   # 终端彩色表格
.build/release/DevScope --json   # JSON 输出（可接入其他工具）
```

## 识别规则摘要

| 来源 | 处理 |
| --- | --- |
| 系统进程 / GUI 应用（QQ、微信、IDE…） | 自动过滤（按路径与 `.app` 包） |
| `node .../node_modules/.bin/vite` 等 | 识别为 前端 · Vite |
| `go run` 临时二进制（go-build 缓存路径） | 识别为 后端 · Go |
| Docker 转发端口 | 关联容器镜像与 compose 项目标签 |
| `package.json` / `pyproject.toml` 依赖 | 精修技术栈名（Express / FastAPI …） |

要求：macOS 13+，Xcode Command Line Tools。
