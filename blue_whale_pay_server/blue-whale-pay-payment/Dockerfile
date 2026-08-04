#
#   blue-whale-pay-payment（支付网关）多阶段镜像构建
#   阶段1：Maven 编译（从父工程根编译目标模块 + 依赖模块）
#   阶段2：JRE 运行
#

# 阶段1：编译
FROM maven:3-eclipse-temurin-17 AS builder
WORKDIR /build
COPY . .
RUN mvn package -pl blue-whale-pay-payment -am -DskipTests

# 阶段2：运行
FROM eclipse-temurin:17-jre
LABEL maintainer="Blue-Whale"
ENV LANG=C.UTF-8
ENV TZ=Asia/Shanghai

EXPOSE 9216
VOLUME ["/jeepayhomes/service/logs", "/jeepayhomes/service/uploads"]

RUN mkdir -p /jeepayhomes/service/app

COPY --from=builder /build/blue-whale-pay-payment/target/blue-whale-pay-payment.jar /jeepayhomes/service/app/jeepay-payment.jar

WORKDIR /jeepayhomes/service/app

CMD ["java", "-jar", "jeepay-payment.jar", "--spring.config.additional-location=file:/jeepayhomes/service/app/application.yml"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD bash -c 'echo > /dev/tcp/localhost/9216'