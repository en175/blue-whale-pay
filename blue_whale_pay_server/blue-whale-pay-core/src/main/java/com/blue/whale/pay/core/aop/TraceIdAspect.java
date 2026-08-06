package com.blue.whale.pay.core.aop;

import com.blue.whale.pay.core.utils.TraceIdKit;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.aspectj.lang.annotation.Pointcut;
import org.springframework.stereotype.Component;

/*
* 链路标识 (trace_id) 兜底切面
*
* HTTP 入口以外的执行入口（MQ 业务接收器、 定时任务）不经过 TraceIdFilter， MDC 为空；
* 本切面在这些入口统一生成 trace_id, 保证：
* 1. 全部日志行携带 trace_id;
* 2. 这些入口触发的出站 HTTP 调用（商户通知/渠道查单等）携带 X-Trace-Id。
*
* 业务代码零侵入： 不修改任何 MQ 接收器/定时任务实现类。
*/
@Component
@Aspect
public class TraceIdAspect {

    /** MQ 业务接收器入口： 各模块 mq 包下的 xxMQReceiver.receive(..) 方法 **/
    @Pointcut("execution(* com.blue.whale.pay..mq..*MQReceiver.receive(..))")
    public void mqReceiverPointcut() { }

    /** Spring 定时任务入口 **/
    @Pointcut("@annotation(org.springframework.scheduling.annotation.Scheduled)")
    public void scheduledPointcut() { }

    @Around("mqReceiverPointcut() || scheduledPointcut()")
    public Object around(ProceedingJoinPoint point) throws Throwable {
        boolean created = TraceIdKit.initIfAbsent();
        try {
            return point.proceed();
        } finally {
            //仅当本切面新生成时清理， 避免误清上游透传的 trace_id
            if (created) {
                TraceIdKit.clear();
            }
        }
    }

}
