FROM alpine:3.20
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories && \
    apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY new-api /app/new-api
RUN chmod +x /app/new-api
EXPOSE 3000
ENTRYPOINT ["/app/new-api"]
