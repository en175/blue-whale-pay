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
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.blue.whale.pay.pay.channel.AbstractPaymentService;
import com.blue.whale.pay.pay.channel.IPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.util.PaywayUtil;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.stereotype.Service;

import java.util.Map;
import java.util.TreeMap;

/*
 * 杭州银行线上支付平台 支付服务
 *
 * 支付方式：聚合主扫（wayCode = HCCB_QR）
 * 一个二维码，用户在银行统一收银台上自选微信/支付宝/云闪付，渠道对商户透明。
 */
@Service
@Slf4j
public class HccbPaymentService extends AbstractPaymentService {

    @Override
    public String getIfCode() {
        return CS.IF_CODE.HCCB;
    }

    @Override
    public boolean isSupport(String wayCode) {
        return CS.PAY_WAY_CODE.HCCB_QR.equals(wayCode);
    }

    @Override
    public String preCheck(UnifiedOrderRQ rq, PayOrder payOrder) {
        IPaymentService realService = PaywayUtil.getRealPaywayService(this, payOrder.getWayCode());
        if (realService == null) {
            return "杭州银行不支持的支付方式：" + payOrder.getWayCode();
        }
        return realService.preCheck(rq, payOrder);
    }

    @Override
    public AbstractRS pay(UnifiedOrderRQ rq, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {
        IPaymentService realService = PaywayUtil.getRealPaywayService(this, payOrder.getWayCode());
        if (realService == null) {
            throw new IllegalArgumentException("杭州银行不支持的支付方式：" + payOrder.getWayCode());
        }
        return realService.pay(rq, payOrder, mchAppConfigContext);
    }

    // ------------------------------------------------------------------ 供 payway 复用的公共能力

    /** 取渠道配置 */
    protected HccbNormalMchParams getMchParams(MchAppConfigContext ctx) {
        return (HccbNormalMchParams) configContextQueryService.queryNormalMchParams(
                ctx.getMchNo(), ctx.getAppId(), getIfCode());
    }

    /** 组装公共报文头：每次请求都会带上的固定域 */
    protected Map<String, Object> buildCommonParams(HccbNormalMchParams cfg) {
        Map<String, Object> params = new TreeMap<>();
        // 对外部商户接入的固定常量，写死在代码里，不开放配置
        params.put("encoding", HccbKit.ENCODING);
        params.put("signMethod", HccbKit.SIGN_METHOD);
        params.put("aesWay", HccbKit.AES_WAY_EXTERNAL);
        params.put("sdkAppId", cfg.getSdkAppId());
        params.put("merId", cfg.getMerId());
        params.put("certId", cfg.getCertId());
        return params;
    }

    /**
     * 统一请求流程：加签 → POST → 验签。
     *
     * @param retMsg 用于回填失败原因
     * @return 验签通过的响应对象；任何环节失败返回 null 并已回填 retMsg
     */
    protected JSONObject request(HccbNormalMchParams cfg, Map<String, Object> params, ChannelRetMsg retMsg) {

        String certPath;
        byte[] cert;
        try {
            // 与 ysfpay/wxpay 一致：由 ChannelCertConfigKitBean 解析为本地绝对路径
            certPath = channelCertConfigKitBean.getCertFilePath(cfg.getMchCertFile());
            cert = HccbKit.readCertFile(certPath);
        } catch (Exception e) {
            log.error("[hccb] 加载商户证书失败", e);
            retMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
            retMsg.setChannelErrCode("CERT_ERROR");
            retMsg.setChannelErrMsg("加载商户证书失败：" + e.getMessage());
            return null;
        }

        // 先构造待发送报文，再对其签名 —— 保证「签名的字段集 == 发送的字段集」
        Map<String, Object> body = new TreeMap<>(params);

        String sign;
        try {
            sign = HccbKit.sign(body, cert, cfg.getMchCertPwd());
        } catch (Exception e) {
            // Demo 在此处返回字符串冒充签名值，导致下游静默失败；此处如实失败
            log.error("[hccb] 加签失败", e);
            retMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
            retMsg.setChannelErrCode("SIGN_ERROR");
            retMsg.setChannelErrMsg("加签失败：" + e.getMessage());
            return null;
        }

        body.put(HccbKit.SIGN_FIELD, sign);

        String respStr = HccbKit.doPostJson(cfg.getPayUrl(), body);
        if (StringUtils.isBlank(respStr)) {
            // 网络异常 → 交由轮询查单确认，不武断判失败
            retMsg.setChannelState(ChannelRetMsg.ChannelState.WAITING);
            return null;
        }

        JSONObject resp;
        try {
            resp = JSON.parseObject(respStr);
        } catch (Exception e) {
            log.error("[hccb] 响应报文解析失败：{}", respStr, e);
            retMsg.setChannelState(ChannelRetMsg.ChannelState.WAITING);
            return null;
        }

        try {
            String respSign = resp.getString(HccbKit.SIGN_FIELD);
            if (!HccbKit.verify(resp, respSign, cfg.getBankCertId())) {
                log.error("[hccb] 响应验签失败：{}", respStr);
                retMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
                retMsg.setChannelErrCode(ERR_VERIFY);
                retMsg.setChannelErrMsg("响应报文验签失败");
                return null;
            }
        } catch (Exception e) {
            log.error("[hccb] 响应验签异常", e);
            retMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
            retMsg.setChannelErrCode(ERR_VERIFY);
            retMsg.setChannelErrMsg("响应报文验签异常");
            return null;
        }

        // 渠道原始响应，供管理端排查
        retMsg.setChannelOriginResponse(respStr);

        return resp;
    }

    /** 验签失败的错误码：请求已发出、但响应不可信，属「结果未知」 */
    public static final String ERR_VERIFY = "VERIFY_ERROR";

    /** 按应答码回填失败信息 */
    protected void fillFail(ChannelRetMsg retMsg, JSONObject resp) {
        retMsg.setChannelState(ChannelRetMsg.ChannelState.CONFIRM_FAIL);
        retMsg.setChannelErrCode(resp.getString("respCode"));
        retMsg.setChannelErrMsg(resp.getString("respMsg"));
    }

}
