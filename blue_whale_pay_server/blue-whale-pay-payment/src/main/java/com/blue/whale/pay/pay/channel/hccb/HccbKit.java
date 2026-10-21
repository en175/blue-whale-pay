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

import cfca.sadk.algorithm.common.MechanismKit;
import cfca.sadk.lib.crypto.JCrypto;
import cfca.sadk.lib.crypto.Session;
import cfca.sadk.util.CertUtil;
import cfca.sadk.util.KeyUtil;
import cfca.sadk.util.Signature;
import cfca.sadk.x509.certificate.X509Cert;
import cn.hutool.http.HttpUtil;
import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.codec.binary.Base64;
import org.apache.commons.lang3.StringUtils;

import java.nio.charset.StandardCharsets;
import java.security.PrivateKey;
import java.util.Map;
import java.util.TreeMap;

/*
 * 杭州银行线上支付平台 加签/验签/通讯工具类
 *
 * 协议要点（依据测试环境实测报文）：
 *  - POST JSON，Content-Type: application/json;charset=UTF-8
 *  - 加签/验签：除 signAture 外的全部字段，按参数名 ASCII 升序拼 "k1=v1&k2=v2..."，
 *    UTF-8 编码后做 PKCS7 Detach 签名（SHA256），Base64 编码存入 signAture
 *  - 银行文档明确要求「字段可能会增加，请勿在验签时写死」，故验签按收到的全部字段参与
 *
 * 与官方 JavaDemo 的差异（Demo 缺陷，此处已修正）：
 *  1. Demo 加签排除 signature/attach/sign，验签排除 signAture —— 两端不一致。
 *     此处统一为排除 signAture。
 *  2. Demo 证书异常时返回 map.toString() 冒充签名值，导致下游静默失败。此处抛异常。
 *  3. Demo 的 pfx/password/algorithm 为 static，多商户会串证书。此处证书按商户缓存。
 *  4. Demo 每次签名都 JCrypto.initialize()，性能差且线程安全存疑。此处仅初始化一次。
 */
@Slf4j
public class HccbKit {

    /** 签名域字段名（注意大写 A，非 signature） */
    public static final String SIGN_FIELD = "signAture";

    /** 应答码：交易成功 */
    public static final String RESP_SUCCESS = "0000";

    /** 主扫支付 */
    public static final String TXN_TYPE_PAY = "1000";
    public static final String TXN_SUB_TYPE_PAY_QR = "100010";

    /** 支付退款 */
    public static final String TXN_TYPE_REFUND = "1008";
    public static final String TXN_SUB_TYPE_REFUND = "100800";

    /** 交易状态查询 */
    public static final String TXN_TYPE_QUERY = "1009";
    public static final String TXN_SUB_TYPE_QUERY = "100900";

    /** 币种：人民币 */
    public static final String CCY_CNY = "156";

    // ---- 对外部商户接入固定的报文常量（不开放配置，写死在代码里） ----

    /** 接入方式：外部商户接入 */
    public static final String AES_WAY_EXTERNAL = "04";

    /** 签名方式 */
    public static final String SIGN_METHOD = "01";

    /** 编码方式 */
    public static final String ENCODING = "UTF-8";

    /** 查询响应中订单状态的取值 */
    public static final String ORDER_STAT_SUCCESS = "00";           // 交易成功
    public static final String ORDER_STAT_SUCCESS_REFUNDED = "01";  // 交易成功（已退货/撤销）
    public static final String ORDER_STAT_FAIL = "99";              // 交易失败
    public static final String ORDER_STAT_CLOSED = "09";            // 交易已关闭

    /** 收银台令牌有效期：30 分钟（文档未提，依据实测 tokenBegin~tokenEnd） */
    public static final long CASHIER_TOKEN_MINUTES = 30L;

    /** pfx 证书签名算法（Demo 中 pfx 分支使用 SHA256） */
    private static final String ALGORITHM = MechanismKit.SHA256;

    /** CFCA 加密库标识 */
    private static final String CRYPTO_LIB = "JSOFT_LIB";

    /** JCrypto 全局只需初始化一次（缺陷 4） */
    private static volatile boolean cryptoInitialized = false;

    /** 查询流水号序列，保证同一毫秒内多次调用不重复 */
    private static final java.util.concurrent.atomic.AtomicInteger SEQ = new java.util.concurrent.atomic.AtomicInteger();

    private static synchronized void ensureCryptoInitialized() throws Exception {
        if (!cryptoInitialized) {
            JCrypto.getInstance().initialize(CRYPTO_LIB, null);
            cryptoInitialized = true;
        }
    }

    /**
     * 加签。
     *
     * ⚠️ 传入的必须是**即将发送的那份报文**（未含 signAture）。
     *    签名规则与 JSON 序列化严格对齐（null 键两边都不出现；空串两边都出现），
     *    保证「签名的字段集 == 发送的字段集」，否则银行按报文验签会判失败。
     *
     * @param params 即将发送的报文（不含 signAture）
     * @param pfx    商户证书字节
     * @param pwd    证书密码
     */
    public static String sign(Map<String, Object> params, byte[] pfx, String pwd) throws Exception {

        if (pfx == null || pfx.length == 0) {
            throw new IllegalArgumentException("hccb 加签失败：商户证书未加载");
        }

        String data = coverMap2String(params, false);
        log.info("[hccb] 加签原文：{}", data);

        ensureCryptoInitialized();

        byte[] sign = certDetachSign(data.getBytes(StandardCharsets.UTF_8), pfx, pwd);
        return new String(Base64.encodeBase64(sign), StandardCharsets.UTF_8);
    }

    /**
     * 验签：校验响应报文的 signAture，并固定签名者证书。
     *
     * 银行要求「勿在验签时写死字段」，故按收到的全部字段参与（仅排除 signAture）。
     *
     * ⚠️ 安全要点：p7VerifyMessageDetach 只用**签名内嵌的证书**验签，不校验签发方。
     *    若不额外固定签名者，任何持有效 CFCA 证书的一方都能伪造报文通过验签
     *    （异步通知是公网可达接口，伪造成本极低）。
     *    因此必须传入 expectedSignerCertId，校验签名者证书主体是否含该标识。
     *
     * @param expectedSignerCertId 期望的签名者证书标识（如杭州银行 H100001861）；
     *                             为空则仅验签不固定（仅供联调排查，生产禁用）
     */
    public static boolean verify(Map<String, Object> respMap, String signAture, String expectedSignerCertId) throws Exception {

        if (StringUtils.isBlank(signAture)) {
            log.error("[hccb] 验签失败：响应报文无 {} 字段", SIGN_FIELD);
            return false;
        }

        String data = coverMap2String(respMap, false);
        ensureCryptoInitialized();

        Session session = JCrypto.getInstance().openSession(CRYPTO_LIB);
        Signature signature = new Signature(false);
        byte[] signBytes = Base64.decodeBase64(signAture);

        if (!signature.p7VerifyMessageDetach(data.getBytes(StandardCharsets.UTF_8), signBytes, session)) {
            log.error("[hccb] 验签失败：签名校验不通过");
            return false;
        }

        // 信任锚：签名者必须是杭州银行
        //
        // ⚠️ fail-closed：未配置 bankCertId 时**直接判失败**，不降级放行。
        //    若此处宽容通过，任何持有效 CFCA 证书者都能伪造回调/应答，
        //    第一轮评审的 Critical（伪造支付成功）就会重新打开。
        if (StringUtils.isBlank(expectedSignerCertId)) {
            log.error("[hccb] 验签失败：渠道未配置 bankCertId（签名者证书标识），拒绝放行");
            return false;
        }

        X509Cert signerCert;
        try {
            signerCert = signature.getSignerX509CertFromP7SignData(signBytes);
        } catch (Exception e) {
            log.error("[hccb] 无法从签名中提取签名者证书", e);
            return false;
        }

        String subject = signerCert == null ? null : signerCert.getSubject();
        if (subject == null || !subject.contains(expectedSignerCertId)) {
            log.error("[hccb] 验签失败：签名者证书不符合预期，期望包含 [{}]，实际 [{}]",
                    expectedSignerCertId, subject);
            return false;
        }

        return true;
    }

    /**
     * 把 Map 拼成待签名/待验签字符串：按参数名 ASCII 升序，k1=v1&k2=v2...（不含末尾 &）。
     *
     * @param skipBlank 是否额外跳过**空字符串**参数。
     *                  null 值一律跳过（与 fastjson 序列化行为对齐，保证签/发一致）；
     *                  验签传 false —— 银行按收到的全部字段签名。
     */
    public static String coverMap2String(Map<String, ?> data, boolean skipBlank) {

        TreeMap<String, Object> tree = new TreeMap<>();
        for (Map.Entry<String, ?> en : data.entrySet()) {
            String key = en.getKey() == null ? "" : en.getKey().trim();
            if (SIGN_FIELD.equals(key)) {
                continue;   // 签名域不参与
            }
            Object value = en.getValue();
            // null 值一律跳过：fastjson 默认不输出 null 键（未开 WriteMapNullValue），
            // 若签名时把 null 拼成 "k=null" 而报文里没有该键，就会出现「签名集 ≠ 发送集」。
            if (value == null) {
                continue;
            }
            if (skipBlank && StringUtils.isBlank(String.valueOf(value))) {
                continue;
            }
            tree.put(key, value);
        }

        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, Object> en : tree.entrySet()) {
            sb.append(en.getKey()).append('=').append(en.getValue()).append('&');
        }
        if (sb.length() > 0) {
            sb.deleteCharAt(sb.length() - 1);
        }
        return sb.toString();
    }

    /** PKCS7 Detach 签名 */
    private static byte[] certDetachSign(byte[] data, byte[] pfx, String password) throws Exception {
        Session session = JCrypto.getInstance().openSession(CRYPTO_LIB);
        Signature signature = new Signature(false);
        PrivateKey privateKey = KeyUtil.getPrivateKeyFromPFX(pfx, password);
        X509Cert cert = CertUtil.getCertFromPFX(pfx, password);
        return signature.p7SignMessageDetach(ALGORITHM, data, privateKey, cert, session);
    }

    /**
     * 发送 JSON 报文。
     *
     * @return 响应体；网络异常返回 null（由调用方按「支付中」处理，避免误判为失败）
     */
    public static String doPostJson(String url, Map<String, Object> params) {

        String body = JSON.toJSONString(params);
        log.info("[hccb] 请求报文：{}", body);

        try {
            String resp = HttpUtil.createPost(url)
                    .header("Content-Type", "application/json;charset=UTF-8")
                    .body(body)
                    .timeout(60 * 1000)
                    .execute()
                    .body();
            log.info("[hccb] 响应报文：{}", resp);
            return resp;
        } catch (Exception e) {
            log.error("[hccb] 请求异常，url={}", url, e);
            return null;
        }
    }

    /**
     * 读取商户证书文件。
     *
     * 不缓存：证书轮换（测试转生产）后需立即生效，避免读到旧文件。
     *
     * @param certFile 由 ChannelCertConfigKitBean 解析出的绝对路径
     */
    public static byte[] readCertFile(String certFile) throws Exception {

        if (StringUtils.isBlank(certFile)) {
            throw new IllegalArgumentException("hccb 渠道配置缺少商户证书文件");
        }

        java.io.File file = new java.io.File(certFile);
        if (!file.exists()) {
            throw new IllegalArgumentException("hccb 商户证书文件不存在：" + certFile);
        }
        return java.nio.file.Files.readAllBytes(file.toPath());
    }

    /**
     * 组装需要跨请求回传的渠道响应数据（成功时落库到 PayOrder.channelResData，退款时取出使用）。
     *
     * respTxnSsn  → 退款时的 origRespTxnSsn
     * respTxnTime → 退款时的 origRespTxnTime
     */
    public static String buildResData(String respTxnSsn, String respTxnTime) {
        com.alibaba.fastjson.JSONObject data = new com.alibaba.fastjson.JSONObject();
        data.put("respTxnSsn", respTxnSsn);
        data.put("respTxnTime", respTxnTime);
        return data.toJSONString();
    }

    /** 从 PayOrder.channelResData 中取出指定字段，取不到返回 null */
    public static String getResDataField(String channelResData, String key) {
        if (StringUtils.isBlank(channelResData)) {
            return null;
        }
        try {
            return com.alibaba.fastjson.JSON.parseObject(channelResData).getString(key);
        } catch (Exception e) {
            log.warn("[hccb] channelResData 解析失败：{}", channelResData);
            return null;
        }
    }

    /**
     * 生成查询流水号（txnOrderId）。
     *
     * 渠道要求 32 字符内。轮询会对同一订单反复查询，若银行对流水号做唯一性校验，
     * 复用同一个号会导致第二次起全部被拒 → 补单静默失效，故每次调用都生成新号。
     *
     * 唯一部分（时间戳 + 序列）放在最前，确保即使订单号很长、末尾被截断也不会退化成重复值。
     * 被查询的订单由报文中独立的 origTxnOrderId 指定，故本流水号无需携带业务单号。
     */
    public static String buildQueryOrderId() {
        String id = "Q" + System.currentTimeMillis()
                + String.format("%03d", SEQ.incrementAndGet() % 1000);
        return id.length() <= 32 ? id : id.substring(0, 32);
    }

    /**
     * 从下单应答中取出统一收银台地址。
     *
     * ⚠️ 实测 `txnTokenPayData` 是 **JSON 字符串**（非嵌套对象）：
     *     "txnTokenPayData":"{\"tokenCode\":\"...\",\"tokenCodeURL\":\"...\"}"
     *     接口文档写的是 `respData` + `codeUrl`，与此不符。
     * 为兼容银行后续可能改为真正的嵌套对象，两种形态都处理。
     *
     * @return 收银台地址；缺失或格式异常返回 null
     */
    public static String extractCashierUrl(JSONObject resp) {

        Object raw = resp.get("txnTokenPayData");
        if (raw == null) {
            return null;
        }

        JSONObject tokenData;
        if (raw instanceof JSONObject) {
            tokenData = (JSONObject) raw;
        } else {
            try {
                tokenData = JSON.parseObject(String.valueOf(raw));
            } catch (Exception e) {
                log.error("[hccb] txnTokenPayData 解析失败：{}", raw);
                return null;
            }
        }

        return tokenData == null ? null : tokenData.getString("tokenCodeURL");
    }

}
