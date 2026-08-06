package com.blue.whale.pay.core.web;

import com.blue.whale.pay.core.utils.TraceIdKit;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

/*
* 跨系统链路标识 (X-Trace-Id) 过滤器
*
* 每个 HTTP 入口： 请求头已带 X-Trace-Id 则沿用（透传优先， 保证链路唯一）， 否则新生成；
* 写入 MDC(key=trace_id)， logback 通过 %X{trace_id} 输出， 同线程日志自动携带 trace_id。
*
* 三个服务(manager/merchant/payment) 均扫描 com.blue.whale.pay.* 包， 本过滤器自动生效。
*/
@Component
@Order(Ordered.HIGHEST_PRECEDENCE) //先于所有过滤器（含 Spring Security）执行， 保证整条请求链路日志均有 trace_id
public class TraceIdFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {

        //透传优先： 入口已带 X-Trace-Id 则沿用； 值非法时重新生成（防止非法字符注入日志）
        String traceId = request.getHeader(TraceIdKit.TRACE_ID_HEADER);
        if (!TraceIdKit.isValid(traceId)) {
            traceId = TraceIdKit.generateTraceId();
        }
        TraceIdKit.setTraceId(traceId);

        //响应头回显， 便于跨系统链路排查
        response.setHeader(TraceIdKit.TRACE_ID_HEADER, traceId);

        try {
            filterChain.doFilter(request, response);
        } finally {
            //容器线程复用， 必须清理 MDC 防止串号
            TraceIdKit.clear();
        }
    }

}
