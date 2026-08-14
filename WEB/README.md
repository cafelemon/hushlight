# Hushlight Web

小熙的 Web 控制台 W0 工程骨架。当前使用明确标注的本地预览数据，不代表云端、设备或 PC Bridge 已接入。

## 本地运行

```bash
npm install
npm run dev
```

默认地址：`http://localhost:4173`

## 验证

```bash
npm run typecheck
npm test
npm run test:ui
npm run build
```

`npm run test:ui` 会自动启动仅供测试使用的本地 Vite 服务，并检查四个固定视口。完整顺序可使用 `npm run test:all`。

产品、架构和验收入口见 [`docs/00_overview.md`](docs/00_overview.md)。
