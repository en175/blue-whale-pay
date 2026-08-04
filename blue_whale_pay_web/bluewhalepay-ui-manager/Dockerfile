# bluewhalepay-ui-manager 镜像构建
# 多阶段：Vite 构建 → Nginx 运行
FROM node:20-alpine AS builder

WORKDIR /workspace
COPY . /workspace

RUN npm config set registry https://registry.npmmirror.com
RUN cd /workspace/bluewhalepay-ui-manager && npm install && npm run build

FROM nginx:alpine

ENV BACKEND_HOST=localhost:9217

WORKDIR /workspace
COPY --from=builder /workspace/bluewhalepay-ui-manager/dist /workspace
RUN chmod -R a+r /workspace
RUN rm -rf /etc/nginx/conf.d/default.conf
COPY --from=builder /workspace/default.conf.template /etc/nginx/templates/default.conf.template

# docker build -t bluewhalepay-ui-manager:latest .
# docker run -d -p 9227:80 -e BACKEND_HOST=172.20.0.22:9217 bluewhalepay-ui-manager:latest