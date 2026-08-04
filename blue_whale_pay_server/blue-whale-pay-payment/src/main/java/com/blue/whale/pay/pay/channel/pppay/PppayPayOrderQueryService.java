package com.blue.whale.pay.pay.channel.pppay;

import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.pay.channel.IPayOrderQueryService;
import com.blue.whale.pay.pay.model.MchAppConfigContext;
import com.blue.whale.pay.pay.rqrs.msg.ChannelRetMsg;
import com.blue.whale.pay.pay.service.ConfigContextQueryService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

/**
 * none.
 *
 * @author 陈泉
 * @package com.blue.whale.pay.pay.channel.pppay
 * @create 2021/11/15 21:02
 */
@Service
public class PppayPayOrderQueryService implements IPayOrderQueryService {

    @Override
    public String getIfCode() {
        return CS.IF_CODE.PPPAY;
    }

    @Autowired
    private ConfigContextQueryService configContextQueryService;

    @Override
    public ChannelRetMsg query(PayOrder payOrder, MchAppConfigContext mchAppConfigContext) throws Exception {
        return configContextQueryService.getPaypalWrapper(mchAppConfigContext).processOrder(null, payOrder);
    }
}
