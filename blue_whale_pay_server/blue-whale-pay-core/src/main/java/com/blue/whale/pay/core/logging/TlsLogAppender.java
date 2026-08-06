package com.blue.whale.pay.core.logging;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.UnsynchronizedAppenderBase;
import com.blue.whale.pay.core.utils.TraceIdKit;
import com.volcengine.model.tls.LogItem;
import com.volcengine.model.tls.producer.CallBack;
import com.volcengine.model.tls.producer.ProducerConfig;
import com.volcengine.model.tls.producer.Result;
import com.volcengine.service.tls.Producer;
import com.volcengine.service.tls.ProducerImpl;
import org.apache.commons.lang3.StringUtils;
import org.apache.commons.lang3.time.FastDateFormat;

import java.net.InetAddress;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/*
* 火山引擎 TLS (日志服务) 上报 Appender
*
* 日志字段 Schema 与 blue-whale-api 严格一致（平铺下划线）：
* level, time, container, env, version, trace_id, caller, func, message
* - level: INFO/WARN/ERR（ERROR 映射为 ERR）
* - time: yyyy-MM-dd HH:mm:ss； LogItem 时间戳使用毫秒
* - caller: 类全名:行号； func: 方法名（取自 logback caller data）
* - 系统级/无请求上下文日志： trace_id 为空
* - 未配置完整凭证/topicId 时自动跳过上报， 不影响本地日志输出
* - 采用异步 Producer 上报（批量聚合、 失败重试、 优雅关闭）， 不阻塞业务线程
*/
public class TlsLogAppender extends UnsynchronizedAppenderBase<ILoggingEvent> {

    /** 日志字段 key（与 blue-whale-api 保持一致） */
    private static final String FIELD_LEVEL = "level";
    private static final String FIELD_TIME = "time";
    private static final String FIELD_CONTAINER = "container";
    private static final String FIELD_ENV = "env";
    private static final String FIELD_VERSION = "version";
    private static final String FIELD_TRACE_ID = "trace_id";
    private static final String FIELD_CALLER = "caller";
    private static final String FIELD_FUNC = "func";
    private static final String FIELD_MESSAGE = "message";

    private static final FastDateFormat TIME_FORMAT = FastDateFormat.getInstance("yyyy-MM-dd HH:mm:ss");

    /** 上报失败累计次数（每 100 次输出一条告警， 避免告警风暴） */
    private final AtomicLong failCount = new AtomicLong();

    // ====== 以下属性由 logback-spring.xml 注入 ======
    private String endpoint;   // TLS 公网端点， 需带 https:// 前缀
    private String region;     // 区域， 如 cn-beijing
    private String accessKey;  // AK
    private String secretKey;  // SK（原样使用， 不做 Base64 解码）
    private String topicId;    // 日志主题 ID
    private String container;  // 容器/服务名， 跨系统区分服务
    private String env;        // 环境， 如 dev
    private String version;    // 服务版本
    private String source;     // 日志来源， 缺省取主机名

    private Producer producer;

    @Override
    public void start() {
        if (StringUtils.isAnyBlank(endpoint, region, topicId, accessKey, secretKey)) {
            addWarn("TLS 配置不完整(endpoint/region/topicId/AK/SK), 跳过 TLS 日志上报");
            return;
        }
        try {
            ProducerConfig config = new ProducerConfig(endpoint, region, accessKey, secretKey, "");
            config.setMaxBlockMs(0); //缓冲满时立即抛异常走降级, 绝不阻塞业务线程(默认60s会拖垮交易链路)
            config.setTotalSizeInBytes(20 * 1024 * 1024); //缓冲上限20MB, 限制故障时内存影响面
            producer = new ProducerImpl(config);
            producer.start();
            if (StringUtils.isBlank(source)) {
                source = resolveHostName();
            }
            super.start();
            addInfo("TLS 日志上报已启用, topicId=" + topicId + ", container=" + container + ", env=" + env);
        } catch (Exception e) {
            addError("TLS Producer 启动失败, 跳过 TLS 日志上报", e);
        }
    }

    @Override
    protected void append(ILoggingEvent event) {
        if (!isStarted() || producer == null) {
            return;
        }
        //SDK 内部日志(com.volcengine.*)不得再次上报, 避免 TLS 持续故障时形成 失败->日志->再上报 反馈环
        if (event.getLoggerName() != null && event.getLoggerName().startsWith("com.volcengine")) {
            return;
        }
        try {
            LogItem item = new LogItem(event.getTimeStamp()); //毫秒时间戳

            item.addContent(FIELD_LEVEL, mapLevel(event.getLevel()));
            item.addContent(FIELD_TIME, TIME_FORMAT.format(event.getTimeStamp()));
            item.addContent(FIELD_CONTAINER, StringUtils.defaultString(container));
            item.addContent(FIELD_ENV, StringUtils.defaultString(env));
            item.addContent(FIELD_VERSION, StringUtils.defaultString(version));

            //trace_id: 取自 MDC, 系统级/无请求上下文日志为空
            Map<String, String> mdc = event.getMDCPropertyMap();
            item.addContent(FIELD_TRACE_ID, mdc != null ? StringUtils.defaultString(mdc.get(TraceIdKit.MDC_TRACE_ID)) : "");

            //caller: 类:行号; func: 方法名
            StackTraceElement[] callerData = event.getCallerData();
            if (callerData != null && callerData.length > 0) {
                StackTraceElement caller = callerData[0];
                item.addContent(FIELD_CALLER, caller.getClassName() + ":" + caller.getLineNumber());
                item.addContent(FIELD_FUNC, caller.getMethodName());
            } else {
                item.addContent(FIELD_CALLER, event.getLoggerName());
                item.addContent(FIELD_FUNC, "");
            }

            item.addContent(FIELD_MESSAGE, event.getFormattedMessage());

            producer.sendLogV2(null, topicId, source, event.getLoggerName(), item, SEND_CALLBACK);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (Throwable t) {
            //上报失败不影响业务主流程; Error(如类缺失)同样不得穿透日志框架打崩应用
            if (failCount.incrementAndGet() % 100 == 1) {
                addWarn("TLS 日志上报异常: " + t.getMessage());
            }
        }
    }

    /** 发送结果回调： 失败计数并限流告警 */
    private final CallBack SEND_CALLBACK = new CallBack() {
        @Override
        public void onComplete(Result result) {
            if (result != null && !result.isSuccess() && failCount.incrementAndGet() % 100 == 1) {
                addWarn("TLS 日志上报失败: " + result);
            }
        }
    };

    /** level 映射： ERROR -> ERR, 其余保持原样（INFO/WARN/DEBUG...） */
    private static String mapLevel(Level level) {
        if (Level.ERROR_INT == level.toInt()) {
            return "ERR";
        }
        return level.toString();
    }

    @Override
    public void stop() {
        if (producer != null) {
            try {
                producer.close(3000L); //优雅关闭, 最多等待 3 秒刷出缓冲日志
            } catch (Exception ignore) {
            }
        }
        super.stop();
    }

    private static String resolveHostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (Exception e) {
            return "unknown";
        }
    }

    // ====== logback 属性 setter（XML 注入需要） ======
    public void setEndpoint(String endpoint) { this.endpoint = endpoint; }
    public void setRegion(String region) { this.region = region; }
    public void setAccessKey(String accessKey) { this.accessKey = accessKey; }
    public void setSecretKey(String secretKey) { this.secretKey = secretKey; }
    public void setTopicId(String topicId) { this.topicId = topicId; }
    public void setContainer(String container) { this.container = container; }
    public void setEnv(String env) { this.env = env; }
    public void setVersion(String version) { this.version = version; }
    public void setSource(String source) { this.source = source; }

}
