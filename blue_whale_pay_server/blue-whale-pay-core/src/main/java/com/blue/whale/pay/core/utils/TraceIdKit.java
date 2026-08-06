package com.blue.whale.pay.core.utils;

import org.apache.commons.lang3.StringUtils;
import org.slf4j.MDC;

import java.util.UUID;
import java.util.regex.Pattern;

/*
* 跨系统链路标识 (X-Trace-Id) 工具类
*
* 约定：
* - HTTP 入口通过请求头 X-Trace-Id 透传， 缺省时自动生成；
* - 写入 MDC(key=trace_id)， logback 通过 %X{trace_id} 输出到日志行；
* - 出站 HTTP 调用从 MDC 读取 trace_id 设置到请求头， 实现跨系统链路贯穿。
*/
public class TraceIdKit {

    /** 跨系统链路标识 HTTP 头名称 */
    public static final String TRACE_ID_HEADER = "X-Trace-Id";

    /** MDC 中存放 trace_id 的 key, 对应 logback 的 %X{trace_id} */
    public static final String MDC_TRACE_ID = "trace_id";

    /** 合法 trace_id 格式： 字母或数字开头， 由字母/数字/下划线/短横线组成， 长度 1~64 （防止请求头注入非法字符到日志） */
    private static final Pattern TRACE_ID_PATTERN = Pattern.compile("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$");

    private TraceIdKit() {
    }

    /** 生成一个新的 trace_id (UUID 去横线) **/
    public static String generateTraceId() {
        return UUID.randomUUID().toString().replace("-", "");
    }

    /** 判断 trace_id 是否合法 **/
    public static boolean isValid(String traceId) {
        return StringUtils.isNotBlank(traceId) && TRACE_ID_PATTERN.matcher(traceId).matches();
    }

    /** 获取当前线程的 trace_id **/
    public static String getTraceId() {
        return MDC.get(MDC_TRACE_ID);
    }

    /** 写入 trace_id 到当前线程 MDC **/
    public static void setTraceId(String traceId) {
        MDC.put(MDC_TRACE_ID, traceId);
    }

    /** 清除当前线程的 trace_id （请求/任务结束必须调用， 防止线程复用导致串号） **/
    public static void clear() {
        MDC.remove(MDC_TRACE_ID);
    }

    /**
     * 获取当前 trace_id, 若不存在则新生成一个（不写回 MDC）。
     * 用于出站 HTTP 调用场景， 保证出站请求一定携带 X-Trace-Id。
     */
    public static String getOrGenerate() {
        String traceId = getTraceId();
        return isValid(traceId) ? traceId : generateTraceId();
    }

    /**
     * 当前线程 MDC 无 trace_id 时初始化生成。
     * @return true 表示本次调用新生成（调用方负责在执行结束后 clear）； false 表示已存在（透传自上游）
     */
    public static boolean initIfAbsent() {
        if (isValid(getTraceId())) {
            return false;
        }
        setTraceId(generateTraceId());
        return true;
    }

}
