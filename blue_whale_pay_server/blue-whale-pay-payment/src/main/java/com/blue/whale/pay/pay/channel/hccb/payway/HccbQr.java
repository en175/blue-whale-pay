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
package com.blue.whale.pay.pay.channel.hccb.payway;

import cn.hutool.core.date.DatePattern;
import cn.hutool.core.date.DateUtil;
import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.blue.whale.pay.pay.channel.hccb.HccbKit;
import com.blue.whale.pay.pay.channel.hccb.HccbPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.rqrs.payorder.CommonPayDataRQ;
import com.blue.whale.pay.pay.rqrs.payorder.CommonPayDataRS;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.util.ApiResBuilder;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;

import java.util.Date;
import java.util.Map;

/*
 * 杭州银行 聚合主扫支付（wayCode = HCCB_QR）
 *
 * 一个二维码 → 用户扫码打开杭州银行统一收银台 → 自选微信/支付宝/云闪付。
 * 渠道选择对商户透明，故商户侧不区分支付方式。
 *
 * 应答取 txnTokenPayData.tokenCodeURL（收银台地址）。
 * 注意接口文档写的是 respData + codeUrl/prepayId，与实际不符，此处以实测为准。
 */
@Service("hccbPaymentByHccbQrService") //Service Name需保持全局唯一性
@Slf4j
public class HccbQr extends HccbPaymentService {

    @Override
    public String preCheck(UnifiedOrderRQ rq, PayOrder payOrder) {

        // 银行收银台令牌有效期 30 分钟（实测 tokenBegin~tokenEnd）。
        // 若本地订单有效期短于令牌有效期，会出现「本地已关单、用户仍能付款成功」——
        // 届时 updateIng2Success 因订单非支付中而失败，钱收了却记为已关闭。
        if (payOrder.getExpiredTime() != null) {
            long required = HccbKit.CASHIER_TOKEN_MINUTES * 60_000L;
            long millisLeft = payOrder.getExpiredTime().getTime() - System.currentTimeMillis();

            // 允许 1 秒测量误差：expiredTime 由商户按整分钟设置，走到这里已过去若干毫秒，
            // 不补偿的话"正好 30 分钟"会被判成 29.99 分钟而误拒（错误信息也会自相矛盾）。
            if (millisLeft < required - 1000L) {
                return "订单有效期不能短于 " + HccbKit.CASHIER_TOKEN_MINUTES
                        + " 分钟（银行收银台令牌有效期），当前约 " + Math.max(0, millisLeft / 60000) + " 分钟";
            }
        }
        return null;
    }

    @Override
    public AbstractRS pay(UnifiedOrderRQ rq, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) {

        HccbNormalMchParams cfg = getMchParams(mchAppConfigContext);

        Map<String, Object> params = buildCommonParams(cfg);
        params.put("txnType", HccbKit.TXN_TYPE_PAY);
        params.put("txnSubType", HccbKit.TXN_SUB_TYPE_PAY_QR);
        params.put("backEndUrl", getNotifyUrl(payOrder.getPayOrderId()));
        params.put("txnOrderId", payOrder.getPayOrderId());
        params.put("txnOrderTime", DateUtil.format(new Date(), DatePattern.PURE_DATETIME_PATTERN));
        // 主题与描述都为空时回落订单号：加签会跳过空值字段，若此处留空，
        // 会出现「签名的字段集 ≠ 发送的字段集」，被银行判为验签失败。
        params.put("txnOrderBody", StringUtils.defaultIfBlank(
                StringUtils.defaultIfBlank(payOrder.getSubject(), payOrder.getBody()),
                payOrder.getPayOrderId()));
        params.put("txnAmt", String.valueOf(payOrder.getAmount()));
        params.put("txnCcyType", HccbKit.CCY_CNY);

        CommonPayDataRS res = ApiResBuilder.buildSuccess(CommonPayDataRS.class);
        ChannelRetMsg channelRetMsg = new ChannelRetMsg();
        res.setChannelRetMsg(channelRetMsg);

        // 加签 → POST → 验签
        JSONObject resp = request(cfg, params, channelRetMsg);
        if (resp == null) {
            return res; // 失败原因已回填，或已置为 WAITING 交由轮询确认
        }

        if (!HccbKit.RESP_SUCCESS.equals(resp.getString("respCode"))) {
            fillFail(channelRetMsg, resp);
            return res;
        }

        // 统一收银台地址（txnTokenPayData 实测为 JSON 字符串，见 HccbKit.extractCashierUrl）
        String cashierUrl = HccbKit.extractCashierUrl(resp);
        if (StringUtils.isBlank(cashierUrl)) {
            log.error("[hccb] 下单成功但未返回收银台地址：{}", resp);
            channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
            channelRetMsg.setChannelErrCode("NO_CODE_URL");
            channelRetMsg.setChannelErrMsg("银行未返回收银台地址");
            return res;
        }

        // 平台流水号：退款时作为 origRespTxnSsn 回传
        channelRetMsg.setChannelOrderId(resp.getString("respTxnSsn"));
        // 平台受理时间等：退款时作为 origRespTxnTime 回传，成功时落库
        channelRetMsg.setChannelAttach(HccbKit.buildResData(
                resp.getString("respTxnSsn"), resp.getString("respTxnTime")));

        // 出码
        String payDataType = (rq instanceof CommonPayDataRQ) ? ((CommonPayDataRQ) rq).getPayDataType() : null;
        if (CS.PAY_DATA_TYPE.CODE_IMG_URL.equals(payDataType)) {
            res.setCodeImgUrl(sysConfigService.getDBApplicationConfig().genScanImgUrl(cashierUrl));
        } else {
            res.setCodeUrl(cashierUrl);
        }

        // 下单成功仅代表交易受理，等待用户扫码付款 → 支付中，由回调/轮询确认
        channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.WAITING);

        return res;
    }

}
