# deploy-blue-whale-api

blue_whale_api (new-api, Go) 部署 skill：本地 bun build 前端 + go 交叉编译静态二进制 → scp → 远程 docker build（mirror fallback）→ 检测重启。

## 流程

```
本地 build ──artifact──▶ scp ──▶ 远程 /opt/blue-whale-api/
  前端: bun build → web/default/dist（classic 占位撑 go:embed）
  后端: GOOS=linux GOARCH=amd64 CGO=0 go build → 静态二进制（~113M）
                                        │
                       远程 docker build（alpine:3.20 mirror fallback + apk aliyun + COPY 二进制）
                                        │
                          blue-whale-api:latest
                                        │
                    restart.sh：备份 prev → 检测容器 rm -f → compose up -d（curl 验证 :3001）
                                        │
                    .env 由 push.sh 远程生成（openssl rand SESSION_SECRET，chmod 600）
```

## 目录结构

```
.claude/skills/deploy-blue-whale-api/
├── SKILL.md                     # /deploy-blue-whale-api 入口
├── README.md                    # 本文件
├── scripts/
│   ├── lib.sh                   # 公共配置（密钥/主机/远程目录/mirror/工具函数）
│   ├── build.sh                 # 本地 bun build 前端 + go 交叉编译
│   ├── push.sh                  # scp 二进制+Dockerfile+compose + 远程生成 .env
│   ├── remote-build.sh          # mirror fallback pull alpine + docker compose build
│   ├── restart.sh               # 备份 prev + 检测容器 + 重建 + curl 验证
│   └── deploy.sh                # 一键串联
└── docker/
    ├── Dockerfile               # alpine + apk mirror + COPY 二进制
    └── docker-compose.yml       # 3001:3000, env_file .env
```

## 远程环境假设

- 服务器 `115.190.244.91`，SSH `root@` + `/Users/apple/Downloads/weitian.pem`（与 deploy-blue-whale 同机共存）。
- mysql8(3306)/redis(6379) 已 docker 化运行——new-api 容器经公网 IP 回连。
- new-api 用 MySQL `new-api` 库 + Redis `db1`（与 blue_whale_server `blue_whale` 库 + `db0` 隔离）。
- 远程需 docker compose v2；alpine 由 mirror fallback 拉（不依赖 docker.io 直连）。

## 首次部署步骤

1. 本地 go + bun（`npm install --prefix ~/bun-install bun`，不 sudo）。
2. 远程 docker compose：`ssh -i /Users/apple/Downloads/weitian.pem root@115.190.244.91 'docker compose version'`。
3. 远程 MySQL 建库：`mysql -uroot -p -e "CREATE DATABASE \`new-api\]"`（GORM MySQL 不自动建库）。
4. **云安全组放行 TCP 3001**。
5. 跑 `bash scripts/deploy.sh`。

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `build.sh` bun 未找到 | 装 bun：`npm install --prefix ~/bun-install bun`，或 `BUN=/path/to/bun bash deploy.sh` |
| `build.sh` go build 失败 | dist 缺失（embed）；或未来引入 CGO 依赖。看 go build 输出 |
| `remote-build.sh` 所有 mirror 失败 | 给远程 `/etc/docker/daemon.json` 配 `registry-mirrors`（如 `https://docker.1ms.run`）后 `systemctl restart docker` |
| 容器起不来 | `docker logs blue-whale-api`：多半连不上 mysql8/redis 或 .env 缺 |
| 宿主 curl 通但外部不通 | 云安全组未放行 3001（宿主 iptables 默认 ACCEPT，卡在云安全组） |
| classic 主题空白 | 默认 default 主题；classic 占位，走系统设置切回 default 或修 date-fns |

## 安全约束

- 部署到测试 = outward-facing。脚本只做 build/push/remote-build/restart，**不碰 git**（不提交/推送/PR），符合仓库 git 红线。
- `disable-model-invocation: true`：agent 不自动部署，必须手动 `/deploy-blue-whale-api` 或显式跑脚本。
- `.env` 远程生成 chmod 600，SESSION_SECRET 强随机不落本地；DSN 含 DB 密码经 ssh 加密传输。

## Glossary

| 术语 | 含义 |
|---|---|
| new-api | blue_whale_api 的核心，Go 写的 AI API 网关（fork of one-api） |
| default 主题 | new-api 新前端（React 19, Rsbuild），默认主题 |
| classic 主题 | new-api 老前端（React 18, Semi Design），备选，当前构建失败占位 |
| `go:embed` | Go 编译期把 web/default/dist + web/classic/dist 嵌入二进制；dist 必须存在非空 |
| mirror fallback | 远程拉 alpine 时逐个试国内 docker mirror，绕开 docker.io 墙 |
| 公网 IP 回连 | 容器经宿主公网 IP 访问宿主的 mysql8/redis（同 blue_whale_server 模式） |
| prev 回滚 | restart 前备份 new-api.prev，回滚 = 回退 prev 重建 |
