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
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.blue.whale.pay.pay.channel.IPayOrderQueryService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;

import java.util.Date;
import java.util.Map;

/*
 * 杭州银行 交易状态查询（txnType=1009 / txnSubType=100900）
 *
 * 由 PayOrderReissueTask（每分钟）经 ChannelOrderReissueService 调用，实现补单。
 *
 * 银行只在支付成功时才异步通知 backEndUrl，失败/关单不通知，
 * 因此本接口是**必需**的补偿手段，不是可选项。
 */
@Service
@Slf4j
public class HccbPayOrderQueryService extends HccbPaymentService implements IPayOrderQueryService {

    @Override
    public String getIfCode() {
        return super.getIfCode();
    }

    @Override
    public ChannelRetMsg query(PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {

        HccbNormalMchParams cfg = getMchParams(mchAppConfigContext);

        Map<String, Object> params = buildCommonParams(cfg);
        params.put("txnType", HccbKit.TXN_TYPE_QUERY);
        params.put("txnSubType", HccbKit.TXN_SUB_TYPE_QUERY);
        params.put("txnOrderId", HccbKit.buildQueryOrderId(payOrder.getPayOrderId()));
        params.put("txnOrderTime", DateUtil.format(new Date(), DatePattern.PURE_DATETIME_PATTERN));
        params.put("origTxnOrderId", payOrder.getPayOrderId());

        ChannelRetMsg retMsg = new ChannelRetMsg();
        JSONObject resp = request(cfg, params, retMsg);
        if (resp == null) {
            // 网络/验签异常：不武断判失败，交由下轮轮询
            return ChannelRetMsg.waiting();
        }

        // 查询动作本身失败 → 继续轮询
        if (!HccbKit.RESP_SUCCESS.equals(resp.getString("respCode"))) {
            log.warn("[hccb] 查单未成功 payOrderId={} respCode={} respMsg={}",
                    payOrder.getPayOrderId(), resp.getString("respCode"), resp.getString("respMsg"));
            return ChannelRetMsg.waiting();
        }

        String orderStat = resp.getString("orderStat");
        log.info("[hccb] 查单结果 payOrderId={} orderStat={} origRespCode={} origRespMsg={}",
                payOrder.getPayOrderId(), orderStat, resp.getString("origRespCode"), resp.getString("origRespMsg"));

        // 交易成功（含已发生退货/撤销）：对支付单而言都是「已成功支付」
        if (HccbKit.ORDER_STAT_SUCCESS.equals(orderStat) || HccbKit.ORDER_STAT_SUCCESS_REFUNDED.equals(orderStat)) {
            String ssn = StringUtils.defaultIfBlank(resp.getString("origRespTxnSsn"), payOrder.getChannelOrderNo());
            ChannelRetMsg ok = ChannelRetMsg.confirmSuccess(ssn);
            ok.setChannelAttach(HccbKit.buildResData(
                    StringUtils.defaultIfBlank(resp.getString("origRespTxnSsn"), ssn),
                    resp.getString("origRespTxnTime")));
            return ok;
        }

        // 交易失败 / 已关闭
        if (HccbKit.ORDER_STAT_FAIL.equals(orderStat) || HccbKit.ORDER_STAT_CLOSED.equals(orderStat)) {
            return ChannelRetMsg.confirmFail(resp.getString("origRespCode"), resp.getString("origRespMsg"));
        }

        // 其余（实测 10 等）一律视为中间态：未支付/支付中，继续轮询
        return ChannelRetMsg.waiting();
    }

}
