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
import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.model.params.plspay.PlspayConfig;
import com.jeequan.jeepay.exception.JeepayException;
import com.jeequan.jeepay.model.PayOrderCreateReqModel;
import com.blue.whale.pay.pay.channel.plspay.PlspayKit;
import com.blue.whale.pay.pay.channel.plspay.PlspayPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.rqrs.payorder.payway.WxAppOrderRS;
import com.blue.whale.pay.pay.util.ApiResBuilder;
import com.jeequan.jeepay.response.PayOrderCreateResponse;
import org.springframework.stereotype.Service;

/*
 * 计全付 微信 app支付
 *
 * @author yr
 * @site https://www.jeequan.com
 * @date 2022/8/17 15:50
 */
@Service("plspayPaymentByWxAppService") //Service Name需保持全局唯一性
public class WxApp extends PlspayPaymentService {

    @Override
    public String preCheck(UnifiedOrderRQ rq, PayOrder payOrder) {
        return null;
    }

    @Override
    public AbstractRS pay(UnifiedOrderRQ rq, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {

        // 构造函数响应数据
        WxAppOrderRS res = ApiResBuilder.buildSuccess(WxAppOrderRS.class);
        ChannelRetMsg channelRetMsg = new ChannelRetMsg();
        res.setChannelRetMsg(channelRetMsg);
        try {
            // 构建请求数据
            PayOrderCreateReqModel model = new PayOrderCreateReqModel();
            // 支付方式
            model.setWayCode(PlspayConfig.WX_APP);
            // 异步通知地址
            model.setNotifyUrl(getNotifyUrl());
            // 微信app支付参数
            JSONObject channelExtra = new JSONObject();
            channelExtra.put("payDataType", CS.PAY_DATA_TYPE.WX_APP);
            model.setChannelExtra(channelExtra.toString());

            // 发起统一下单
            PayOrderCreateResponse response = PlspayKit.payRequest(payOrder, mchAppConfigContext, model);
            // 下单返回状态
            Boolean isSuccess = PlspayKit.checkPayResp(response, mchAppConfigContext);

            if (isSuccess) {
                // 下单成功
                JSONObject resJSON = new JSONObject();
                resJSON.put("package", response.getData().getString("payData"));
                res.setPayInfo(resJSON.toJSONString());
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
