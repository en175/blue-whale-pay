package com.blue.whale.pay.pay.config;

import cn.hutool.http.GlobalInterceptor;
import cn.hutool.http.HttpRequest;
import com.blue.whale.pay.core.utils.TraceIdKit;
import org.apache.commons.lang3.StringUtils;
import org.springframework.context.annotation.Configuration;

import jakarta.annotation.PostConstruct;

/*
* 出站 HTTP 链路标识 (X-Trace-Id) 透传配置
*
* 注册 hutool 全局请求拦截器： 所有基于 hutool HttpUtil/HttpRequest 的出站调用
* （渠道请求、 商户异步通知等）自动携带 X-Trace-Id 请求头， 值取自当前线程 MDC, 缺省时生成。
* 业务调用代码零侵入。
*/
@Configuration
public class TraceHttpConfig {

    @PostConstruct
    public void registerTraceIdInterceptor() {
        GlobalInterceptor.INSTANCE.addRequestInterceptor((HttpRequest request) -> {
            //调用方已显式设置时不覆盖
            if (StringUtils.isBlank(request.header(TraceIdKit.TRACE_ID_HEADER))) {
                request.header(TraceIdKit.TRACE_ID_HEADER, TraceIdKit.getOrGenerate());
            }
        });
    }

}
