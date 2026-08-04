package com.blue.whale.pay.pay.channel.pppay;

import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.pay.channel.AbstractPaymentService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.AbstractRS;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.service.ConfigContextQueryService;
import com.blue.whale.pay.pay.util.PaywayUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * none.
 *
 * @author 陈泉
 * @package com.blue.whale.pay.pay.channel.pppay
 * @create 2021/11/15 18:17
 */
@Service
public class PppayPaymentService extends AbstractPaymentService {

    @Autowired
    public ConfigContextQueryService configContextQueryService;

    @Override
    public String getIfCode() {
        return CS.IF_CODE.PPPAY;
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
    public AbstractRS pay(UnifiedOrderRQ bizRQ, PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws
            Exception {
        return PaywayUtil.getRealPaywayService(this, payOrder.getWayCode()).pay(bizRQ, payOrder, mchAppConfigContext);
    }
}
