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

import cn.hutool.core.date.DatePattern;
import cn.hutool.core.date.DateUtil;
import com.alibaba.fastjson.JSONObject;
import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.entity.RefundOrder;
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.blue.whale.pay.pay.channel.IRefundService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.rqrs.refund.RefundOrderRQ;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;

import java.util.Date;
import java.util.Map;

/*
 * 杭州银行 退款（txnType=1008 / txnSubType=100800）
 *
 * 银行要求回传原交易的三个要素，缺一不可：
 *   origTxnOrderId  —— 原商户订单号
 *   origRespTxnSsn  —— 原平台流水号（下单应答 respTxnSsn）
 *   origRespTxnTime —— 原平台受理时间（下单应答 respTxnTime）
 *
 * 后两者在下单成功时由 ChannelRetMsg.channelAttach 落库到 PayOrder.channelResData。
 */
@Service
@Slf4j
public class HccbRefundService extends HccbPaymentService implements IRefundService {

    @Override
    public String getIfCode() {
        return CS.IF_CODE.HCCB;
    }

    @Override
    public String preCheck(RefundOrderRQ bizRQ, RefundOrder refundOrder, PayOrder payOrder) {

        // 退款必需原交易的平台流水号；支付成功时已落库，缺失说明订单异常（如非本渠道支付成功）
        if (StringUtils.isBlank(resolveOrigTxnSsn(payOrder))) {
            return "订单缺少原平台流水号，无法退款（订单可能未成功支付）";
        }
        return null;
    }

    @Override
    public ChannelRetMsg refund(RefundOrderRQ bizRQ, RefundOrder refundOrder, PayOrder payOrder,
                                MchAppConfigContext mchAppConfigContext) throws Exception {

        HccbNormalMchParams cfg = getMchParams(mchAppConfigContext);

        String origTxnSsn = resolveOrigTxnSsn(payOrder);
        String origTxnTime = resolveOrigTxnTime(payOrder);

        // ⚠️ IRefundService.preCheck 在本仓库没有任何调用方
        //    （RefundOrderController 取到 Bean 后直接调 refund），
        //    故前置校验必须内联在此处，否则等于没有校验。
        if (StringUtils.isBlank(origTxnSsn) || StringUtils.isBlank(origTxnTime)) {
            log.error("[hccb] 退款缺少原交易要素 payOrderId={} refundOrderId={} origTxnSsn={} origTxnTime={}",
                    payOrder.getPayOrderId(), refundOrder.getRefundOrderId(), origTxnSsn, origTxnTime);
            ChannelRetMsg fail = new ChannelRetMsg();
            fail.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
            fail.setChannelErrCode("ORIG_TXN_MISSING");
            fail.setChannelErrMsg("订单缺少原平台流水号或受理时间，无法退款");
            return fail;
        }

        Map<String, Object> params = buildCommonParams(cfg);
        params.put("txnType", HccbKit.TXN_TYPE_REFUND);
        params.put("txnSubType", HccbKit.TXN_SUB_TYPE_REFUND);
        params.put("txnOrderId", refundOrder.getRefundOrderId());
        params.put("txnOrderTime", DateUtil.format(new Date(), DatePattern.PURE_DATETIME_PATTERN));
        params.put("origTxnOrderId", payOrder.getPayOrderId());
        params.put("origRespTxnSsn", origTxnSsn);
        params.put("origRespTxnTime", origTxnTime);
        params.put("txnAmt", String.valueOf(refundOrder.getRefundAmount()));
        params.put("txnCcyType", HccbKit.CCY_CNY);

        ChannelRetMsg channelRetMsg = new ChannelRetMsg();

        JSONObject resp = request(cfg, params, channelRetMsg);
        if (resp == null) {
            // ⚠️ 退款是动钱操作：证书/加签/验签异常只说明"我们无法确认这笔退款的结果"，
            //    请求本身可能已被银行成功执行。若在此判 CONFIRM_FAIL，下游会收到"退款失败"
            //    并可能重试 → 银行侧双倍退款。
            //    因此一律降级为 WAITING，交由 RefundOrderReissueTask 走查单收敛。
            if (channelRetMsg.getChannelState() == ChannelRetMsg.ChannelState.CONFIRM_FAIL) {
                log.warn("[hccb] 退款响应无法确认（errCode={}），不判失败，转由轮询查单收敛 refundOrderId={}",
                        channelRetMsg.getChannelErrCode(), refundOrder.getRefundOrderId());
                return ChannelRetMsg.waiting();
            }
            return channelRetMsg;
        }

        if (!HccbKit.RESP_SUCCESS.equals(resp.getString("respCode"))) {
            fillFail(channelRetMsg, resp);
            return channelRetMsg;
        }

        channelRetMsg.setChannelOrderId(resp.getString("respTxnSsn"));
        channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_SUCCESS);
        return channelRetMsg;
    }

    /**
     * 退款查单：复用交易状态查询接口，被查询交易为退款单。
     *
     * 由 RefundOrderReissueTask 调用，用于网络异常时的补偿。
     */
    @Override
    public ChannelRetMsg query(RefundOrder refundOrder, MchAppConfigContext mchAppConfigContext) throws Exception {

        HccbNormalMchParams cfg = getMchParams(mchAppConfigContext);

        Map<String, Object> params = buildCommonParams(cfg);
        params.put("txnType", HccbKit.TXN_TYPE_QUERY);
        params.put("txnSubType", HccbKit.TXN_SUB_TYPE_QUERY);
        params.put("txnOrderId", HccbKit.buildQueryOrderId(refundOrder.getRefundOrderId()));
        params.put("txnOrderTime", DateUtil.format(new Date(), DatePattern.PURE_DATETIME_PATTERN));
        params.put("origTxnOrderId", refundOrder.getRefundOrderId());

        ChannelRetMsg retMsg = new ChannelRetMsg();
        JSONObject resp = request(cfg, params, retMsg);
        if (resp == null) {
            return ChannelRetMsg.waiting();
        }
        if (!HccbKit.RESP_SUCCESS.equals(resp.getString("respCode"))) {
            // 记录失败原因，便于排查「退款单卡住」类问题
            log.warn("[hccb] 退款查单未成功 refundOrderId={} respCode={} respMsg={}",
                    refundOrder.getRefundOrderId(), resp.getString("respCode"), resp.getString("respMsg"));
            return ChannelRetMsg.waiting();
        }

        String orderStat = resp.getString("orderStat");
        log.info("[hccb] 退款查单 refundOrderId={} orderStat={} origRespCode={}",
                refundOrder.getRefundOrderId(), orderStat, resp.getString("origRespCode"));

        if (HccbKit.ORDER_STAT_SUCCESS.equals(orderStat) || HccbKit.ORDER_STAT_SUCCESS_REFUNDED.equals(orderStat)) {
            return ChannelRetMsg.confirmSuccess(
                    StringUtils.defaultIfBlank(resp.getString("origRespTxnSsn"), refundOrder.getChannelOrderNo()));
        }
        if (HccbKit.ORDER_STAT_FAIL.equals(orderStat) || HccbKit.ORDER_STAT_CLOSED.equals(orderStat)) {
            return ChannelRetMsg.confirmFail(resp.getString("origRespCode"), resp.getString("origRespMsg"));
        }
        return ChannelRetMsg.waiting();
    }

    // ------------------------------------------------------------------

    /** 原平台流水号：优先取落库的渠道响应数据，兜底取渠道订单号 */
    private String resolveOrigTxnSsn(PayOrder payOrder) {
        String ssn = HccbKit.getResDataField(payOrder.getChannelResData(), "respTxnSsn");
        return StringUtils.defaultIfBlank(ssn, payOrder.getChannelOrderNo());
    }

    private String resolveOrigTxnTime(PayOrder payOrder) {
        return HccbKit.getResDataField(payOrder.getChannelResData(), "respTxnTime");
    }

}
