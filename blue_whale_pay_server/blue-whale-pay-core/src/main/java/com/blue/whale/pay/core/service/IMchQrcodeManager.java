package com.blue.whale.pay.core.service;

import com.blue.whale.pay.core.entity.PayOrder;

/***
* 码牌相关逻辑
*
* @author terrfly
* @site https://www.jeequan.com
* @date 2024/11/4 15:08
*/
public interface IMchQrcodeManager {

    /**
     * 功能描述: 查询商户配置信息
     *
     * @Return: com.blue.whale.pay.core.entity.PayOrder
     * @Author: terrfly
     * @Date: 2024/11/4 15:14
     */
    PayOrder queryMchInfoByQrc(String id);

}
