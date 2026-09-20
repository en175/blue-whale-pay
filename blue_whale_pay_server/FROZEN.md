# ✅ 已解冻（ACTIVE）

本目录（Java 支付服务）的**冻结已于 2026-09-20 解除**，现为支付建设的现行技术栈。

## 决策依据

[ADR-0001：支付建设阶段开启与 `blue_whale_pay_server` 技术栈归宿](../docs/adr/0001-支付建设阶段开启与技术栈归宿.md)

## 历史背景（冻结期条款，已失效）

本目录自 2026-08-04 起冻结，原依据是兄弟仓 ADR-0055：

> 仓库中尚未落地的 `blue-whale-pay`、Node Payment Gateway、微信/支付宝渠道接入……是未来支付功能……**待产品真正进入支付建设阶段后另行设计和实施**。

2026-09-20 杭州银行（易码付）渠道接入需求触发该条件，ADR-0001 完成「另行决策」，冻结条款随之失效。

## 现行规则

- 本目录**允许新增与修改代码**，遵循本仓常规分支 → PR → 合并流程。
- 渠道接入**沿用既有模式**：`IPaymentService` / `IRefundService` / `IPayOrderQueryService` / `IChannelNoticeService` 四接口 + Spring Bean 名约定（`<ifCode> + 后缀`）+ `payway/` 按 wayCode 反射分派。**不新增抽象层**。
- 轮询补偿**复用** `PayOrderReissueTask` / `RefundOrderReissueTask`，不新增调度器。
- 本目录**不再**适用兄弟仓 CLAUDE.md 红线 #10「禁止新增 Java 产品运行时」——该红线约束产品实现，ADR-0001 已为支付单列归宿。

## 关联

- [ADR-0001](../docs/adr/0001-支付建设阶段开启与技术栈归宿.md)（本仓，现行权威）
- 兄弟仓 `blue-whale-ai` ADR-0055（历史依据，其支付相关条款已由 ADR-0001 承接）
