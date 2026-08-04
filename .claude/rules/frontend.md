---
paths:
  - "blue_whale_web/**"
---

# 前端设计系统

设计系统契约在 `blue_whale_web/DESIGN.md`（`@google/design.md` 格式）：YAML front matter 设计 token（机器可读）+ Markdown 设计理念（人/agent 可读）。

## 规则

- 修改 `blue_whale_web/` 下任何 UI（颜色、字体、圆角、间距、组件样式）前，**必须先读 `blue_whale_web/DESIGN.md`**。
- 颜色/字体/圆角/间距一律使用其中定义的 token，**禁止在组件里硬编码 hex/rgba 值**。新增颜色先在 `colors:` 注册，再用 `{colors.xxx}` 引用。
- 强调色只用 `accent`；状态色只用 `success` / `destructive`；不引入第二个品牌强调色。
- 改完 DESIGN.md 后在 `blue_whale_web/` 运行 `npm run design:lint` 校验（0 errors 通过，warnings 可接受）。
- 导出 Tailwind 主题：`npm run design:export:tw`。

## 补丁注意

`pnpm --filter blue_whale design:spec` 依赖 `blue_whale_web/patches/@google+design.md+0.3.0.patch`（npm 包 0.3.0 缺 `dist/spec.md`，根 `pnpm-workspace.yaml` 的 `patchedDependencies` 会在安装时补回）。**升级 `@google/design.md` 版本后必须重做补丁**：运行 `pnpm patch @google/design.md@<version>`，在临时目录补入 `dist/spec.md`，再运行 `pnpm patch-commit <临时目录>`。
