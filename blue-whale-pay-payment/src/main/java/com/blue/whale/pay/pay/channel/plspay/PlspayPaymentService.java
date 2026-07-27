package com.blue.whale.pay.pay.channel.plspay;

import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.pay.channel.AbstractPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.util.PaywayUtil;
import org.springframework.stereotype.Service;

/**
 * 计全支付plus
 *
 * @author yurong
 * @site https://www.jeequan.com
 * @date 2022/8/11 15:37
 */
@Service
public class PlspayPaymentService extends AbstractPaymentService {

    @Override
    public String getIfCode() {
        return CS.IF_CODE.PLSPAY;
    }

    @Override
    public boolean isSupport(String wayCode) {
        return true;
    }

    @Override
    public String preCheck(UnifiedOrderRQ bizRQ, PayOrder payOrder) {
        return PaywayUtil.getRealPaywayService(this, payOrder.getWayCode()).preCheck(bizRQ, payOrder);
    }

    @Override
    public AbstractRS pay(UnifiedOrderRQ bizRQ, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {
        return PaywayUtil.getRealPaywayService(this, payOrder.getWayCode()).pay(bizRQ, payOrder, mchAppConfigContext);
    }
}
