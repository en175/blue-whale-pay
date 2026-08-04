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
package com.blue.whale.pay.pay.channel.plspay.payway;

import com.alibaba.fastjson.JSONObject;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.exception.BizException;
import com.blue.whale.pay.core.model.params.plspay.PlspayConfig;
import com.jeequan.jeepay.exception.JeepayException;
import com.jeequan.jeepay.model.PayOrderCreateReqModel;
import com.blue.whale.pay.pay.channel.plspay.PlspayKit;
import com.blue.whale.pay.pay.channel.plspay.PlspayPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.rqrs.payorder.payway.WxLiteOrderRQ;
import com.blue.whale.pay.pay.rqrs.payorder.payway.WxLiteOrderRS;
import com.blue.whale.pay.pay.util.ApiResBuilder;
import com.jeequan.jeepay.response.PayOrderCreateResponse;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;

/*
 * 计全付 微信 小程序支付
 *
 * @author yr
 * @site https://www.jeequan.com
 * @date 2022/8/17 15:24
 */
@Service("plspayPaymentByWxLiteService") //Service Name需保持全局唯一性
@Slf4j
public class WxLite extends PlspayPaymentService {

    @Override
    public String preCheck(UnifiedOrderRQ rq, PayOrder payOrder) {
        WxLiteOrderRQ bizRQ = (WxLiteOrderRQ) rq;
        if (StringUtils.isEmpty(bizRQ.getOpenid())) {
            throw new BizException("[openid]不可为空");
        }
        return null;
    }

    @Override
    public AbstractRS pay(UnifiedOrderRQ rq, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {
        WxLiteOrderRQ bizRQ = (WxLiteOrderRQ) rq;
        // 构造函数响应数据
        WxLiteOrderRS res = ApiResBuilder.buildSuccess(WxLiteOrderRS.class);
        ChannelRetMsg channelRetMsg = new ChannelRetMsg();
        res.setChannelRetMsg(channelRetMsg);
        try {
            // 构建请求数据
            PayOrderCreateReqModel model = new PayOrderCreateReqModel();
            // 支付方式
            model.setWayCode(PlspayConfig.WX_LITE);
            // 异步通知地址
            model.setNotifyUrl(getNotifyUrl());
            JSONObject channelExtra = new JSONObject();
            channelExtra.put("openid", bizRQ.getOpenid());
            // 微信openId
            model.setChannelExtra(channelExtra.toString());

            // 发起统一下单
            PayOrderCreateResponse response = PlspayKit.payRequest(payOrder, mchAppConfigContext, model);
            // 下单返回状态
            Boolean isSuccess = PlspayKit.checkPayResp(response, mchAppConfigContext);

            if (isSuccess) {
                // 下单成功
                res.setPayInfo(response.getData().getString("payData"));
                channelRetMsg.setChannelOrderId(response.get().getPayOrderId());
                channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.WAITING);
            } else {
                channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
                channelRetMsg.setChannelErrCode(response.getCode()+"");
                channelRetMsg.setChannelErrMsg(response.getMsg());
            }
        } catch (JeepayException e) {
            channelRetMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
        }
        return res;
    }
}
