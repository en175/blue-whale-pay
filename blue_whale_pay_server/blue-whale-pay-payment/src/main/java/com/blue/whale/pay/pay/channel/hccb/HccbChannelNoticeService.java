/*
 * Copyright (c) 2021-2031, 河北计全科技有限公司 (https://www.jeequan.com & jeequan@126.com).
 * <p>
 * Licensed under the GNU LESSER GENERAL PUBLIC LICENSE 3.0;
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * <p>
 * http://www.gnu.org/licenses/lgpl.html
 * <p>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.blue.whale.pay.pay.channel.hccb;

import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.exception.ResponseException;
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.blue.whale.pay.pay.channel.AbstractChannelNoticeService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.apache.commons.lang3.tuple.MutablePair;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;

import jakarta.servlet.http.HttpServletRequest;

/*
 * 杭州银行 异步通知解析
 *
 * 路由：POST /api/pay/notify/hccb[/{payOrderId}]
 *
 * 报文：JSON body（非表单）。
 *
 * **实测报文（2026-09-22，与接口文档 2.1.5 差异较大）**：
 *   respCode / respMsg / orderStat / txnOrderId / txnOrderTime / txnOrderAmt
 *   respTxnSsn / respTxnTime / settleAmt / settleCcyType / settleDate / settleTime
 *   tpamTxnSsn / txnType / merId / chnlMerId / openId / wxOrderId / respData / signAture
 *
 * ⚠️ 文档写的 txnBankTransId / remark / resv **实际不存在**；实际为 tpamTxnSsn 等。
 *    文档还说「字段可能增加，勿在验签时写死」——验签确实按全字段参与，故新增字段不受影响。
 *
 * ⚠️ 银行只在**支付成功**时通知 backEndUrl，失败/关单不通知。
 *    因此失败判定只能靠查询接口（HccbPayOrderQueryService）。
 *
 * 实测回调延迟：下单后约 65 秒。
 *
 * 安全：验签时固定签名者证书（加密配置 bankCertId），仅接受杭州银行签发的报文。
 *      本接口公网可达，若无此校验，任何持有效 CFCA 证书者都可伪造「支付成功」回调。
 */
@Service
@Slf4j
public class HccbChannelNoticeService extends AbstractChannelNoticeService {

    @Override
    public String getIfCode() {
        return CS.IF_CODE.HCCB;
    }

    @Override
    public MutablePair<String, Object> parseParams(HttpServletRequest request, String urlOrderId,
                                                   NoticeTypeEnum noticeTypeEnum) {
        try {
            JSONObject params = parseBody(request);
            // 订单号优先取报文体的 txnOrderId；取不到时回退 URL 上带的 urlOrderId，
            // 避免银行调整报文格式后整条回调链路直接断掉。
            String payOrderId = params.getString("txnOrderId");
            if (StringUtils.isBlank(payOrderId)) {
                log.warn("[hccb] 回调报文无 txnOrderId，回退使用 urlOrderId={}", urlOrderId);
                payOrderId = urlOrderId;
            }
            log.info("[hccb] 回调报文解析 payOrderId={}", payOrderId);
            return MutablePair.of(payOrderId, params);
        } catch (Exception e) {
            log.error("[hccb] 回调报文解析失败", e);
            throw ResponseException.buildText("ERROR");
        }
    }

    @Override
    public ChannelRetMsg doNotice(HttpServletRequest request, Object params, PayOrder payOrder,
                                  MchAppConfigContext mchAppConfigContext, NoticeTypeEnum noticeTypeEnum) {
        try {
            JSONObject jsonParams = (JSONObject) params;

            // 取渠道配置，用于验签时固定银行签名证书
            HccbNormalMchParams cfg = (HccbNormalMchParams) configContextQueryService.queryNormalMchParams(
                    mchAppConfigContext.getMchNo(), mchAppConfigContext.getAppId(), getIfCode());

            // 验签（含签名者证书固定）
            String signAture = jsonParams.getString(HccbKit.SIGN_FIELD);
            if (!HccbKit.verify(jsonParams, signAture, cfg == null ? null : cfg.getBankCertId())) {
                log.error("[hccb] 回调验签失败 payOrderId={}", payOrder.getPayOrderId());
                throw ResponseException.buildText("ERROR");
            }

            ChannelRetMsg result = new ChannelRetMsg();

            // 验签通过即应答 success，避免银行重复投递
            ResponseEntity okResponse = textResp("success");
            result.setResponseEntity(okResponse);
            result.setChannelState(ChannelRetMsg.ChannelState.WAITING);

            String respCode = jsonParams.getString("respCode");
            // 通知报文同样带 orderStat（实测），与查询接口同义：
            // 00-交易成功 / 01-成功(已退货撤销) / 99-失败 / 09-已关闭
            // 银行文档称仅成功才通知，此处仍一并校验，避免非成功场景被误判。
            String orderStat = jsonParams.getString("orderStat");

            boolean success = HccbKit.RESP_SUCCESS.equals(respCode)
                    && (StringUtils.isBlank(orderStat)
                        || HccbKit.ORDER_STAT_SUCCESS.equals(orderStat)
                        || HccbKit.ORDER_STAT_SUCCESS_REFUNDED.equals(orderStat));

            if (success) {
                String respTxnSsn = jsonParams.getString("respTxnSsn");
                result.setChannelOrderId(respTxnSsn);
                // 平台流水号 + 受理时间：退款需回传，成功时落库到 PayOrder.channelResData
                result.setChannelAttach(HccbKit.buildResData(respTxnSsn, jsonParams.getString("respTxnTime")));
                result.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_SUCCESS);

                // 清算金额与订单金额比对：不一致说明有异常，如实告警（不阻断，respCode 仍是权威）
                String settleAmt = jsonParams.getString("settleAmt");
                if (StringUtils.isNotBlank(settleAmt) && !settleAmt.equals(String.valueOf(payOrder.getAmount()))) {
                    log.warn("[hccb] 回调清算金额与订单金额不一致 payOrderId={} 订单={} 清算={}",
                            payOrder.getPayOrderId(), payOrder.getAmount(), settleAmt);
                }
            } else {
                log.warn("[hccb] 回调非成功状态 payOrderId={} respCode={} orderStat={} respMsg={}",
                        payOrder.getPayOrderId(), respCode, orderStat, jsonParams.getString("respMsg"));
            }

            return result;

        } catch (ResponseException e) {
            throw e;
        } catch (Exception e) {
            log.error("[hccb] 回调处理异常 payOrderId={}", payOrder.getPayOrderId(), e);
            throw ResponseException.buildText("ERROR");
        }
    }

    /** 读取 JSON 请求体 */
    private JSONObject parseBody(HttpServletRequest request) {
        String body = getReqParamFromBody();
        if (StringUtils.isBlank(body)) {
            // 兼容 urlOrderId / 表单形式
            return getReqParamJSON();
        }
        return JSON.parseObject(body);
    }

}
