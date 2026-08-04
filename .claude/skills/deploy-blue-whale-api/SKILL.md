---
name: deploy-blue-whale-api
description: Build blue_whale_api (new-api, Go) into a static linux/amd64 binary locally (bun build default frontend + CGO=0 go build), scp to remote 115.190.244.91, build a minimal alpine image remotely (mirror fallback for alpine, aliyun apk source), detect and restart the container. Generates remote .env with strong random SESSION_SECRET. Use when user wants to deploy new-api / blue_whale_api, or says "部署API"/"发布new-api"/"推API到服务器".
disable-model-invocation: true
---

# Deploy Blue-Whale-API（Go 二进制 → 远程 alpine 镜像）

本地 `bun build` default 前端 + `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build` 出静态二进制 → scp 到 `115.190.244.91:/opt/blue-whale-api/` → 远程 `docker compose build`（mirror fallback 拉 alpine，apk 走 aliyun）→ 检测容器重启。

仅手动 `/deploy-blue-whale-api` 触发（测试部署，禁止 agent 自动）。

> 与 deploy-blue-whale（Java jar）互补：本 skill 专部署 blue_whale_api（new-api，Go）。流程同构（本地 build → scp → 远程 docker build → restart），技术栈适配 Go（交叉编译静态二进制 + alpine）。

## 范围

- **单服务**：blue_whale_api（new-api，Go）。
- 容器内 3000，宿主映射 **3001**（避 blue_whale_web 3000 撞车）。
- 连接：容器经公网 IP 回连宿主 `mysql8:new-api` 库 + `redis:db1`（Redis db1 与其他服务 db0 隔离）。
- SSH：`ssh -i /Users/apple/Downloads/weitian.pem root@115.190.244.91`。

## 前置检查（首次部署前）

1. 本地 `go`（交叉编译）+ `bun`（前端 build，默认 `~/bun-install/node_modules/.bin/bun`；装：`npm install --prefix ~/bun-install bun`，不 sudo）。
2. 远程 docker compose v2：`ssh -i /Users/apple/Downloads/weitian.pem root@115.190.244.91 'docker compose version'`。
3. 远程 MySQL `new-api` 库已建（new-api 首次启动 AutoMigrate 建表；GORM MySQL 不自动 CREATE DATABASE，需手建库）。
4. **云安全组放行 TCP 3001**（宿主 iptables 默认 ACCEPT，外部访问卡在云安全组；不放行外部不可达，但宿主内 curl 通——易误判）。

## 用法

一键全流程：
```bash
bash .claude/skills/deploy-blue-whale-api/scripts/deploy.sh
```

分步：`build.sh` / `push.sh` / `remote-build.sh` / `restart.sh`。

覆盖配置（环境变量）：`DEPLOY_KEY` / `DEPLOY_HOST` / `DEPLOY_USER` / `REMOTE_DIR` / `API_PORT` / `MYSQL_DSN` / `REDIS_DSN` / `BUN`。

## restart 逻辑

备份当前二进制 `new-api.prev`（回滚用）→ `docker ps -a` 查同名容器 → 在跑则 `docker rm -f` → `docker compose up -d` 重建 → curl `/api/status` 重试 8×3s 验证。

## ⚠️ 注意点

- **CGO=0**：new-api 当前纯 Go（MySQL/Redis 驱动无 CGO）。若未来引入 CGO 依赖（如 mattn/go-sqlite3），本地 `CGO_ENABLED=0` build 会失败，需改远程 golang 镜像 build。
- **mirror fallback**：`remote-build.sh` 逐个试 daocloud/1ms/dockerproxy/dockerhub，全失败才报错指路 `/etc/docker/daemon.json` registry-mirrors。不动 docker daemon、不影响测试容器。
- **classic 占位**：classic 前端构建失败（date-fns-tz/date-fns 不兼容），`build.sh` 自动写占位 `index.html` 撑 `go:embed` 编译；默认 default 主题不受影响。
- **SESSION_SECRET**：`push.sh` 远程 `openssl rand -hex 32` 生成强随机（每次部署重新生成 → 已登录 session 失效，可接受；不本地落盘明文）。
- **回滚**：`restart.sh` 前备份 `new-api.prev`；回滚 = `ssh ... 'cd /opt/blue-whale-api && cp new-api.prev new-api'` 再跑 `restart.sh`。
- **外部访问**：`restart.sh` 验证用宿主 `localhost`；外部需云安全组放行 3001。

## 触发示例

用户："部署 API" / "发布 new-api" / "推 API 到服务器" → `deploy.sh`。
用户："只重 build 镜像不改二进制" → `remote-build.sh && restart.sh`。
