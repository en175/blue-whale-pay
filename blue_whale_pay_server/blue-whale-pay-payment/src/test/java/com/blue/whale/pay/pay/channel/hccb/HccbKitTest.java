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

import cn.hutool.core.util.StrUtil;
import com.alibaba.fastjson.JSON;
import com.blue.whale.pay.core.constants.CS;
import java.util.LinkedHashMap;
import java.util.TreeMap;
import com.blue.whale.pay.pay.rqrs.payorder.UnifiedOrderRQ;
import com.blue.whale.pay.pay.channel.hccb.payway.HccbQr;
import com.blue.whale.pay.core.entity.PayOrder;
import com.blue.whale.pay.core.model.params.hccb.HccbNormalMchParams;
import com.alibaba.fastjson.JSONObject;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/*
 * HccbKit 单元测试
 *
 * 其中的「真实响应验签」用例是**关键回归**：它用 2026-09-20 从杭州银行测试环境
 * 实际捕获的下单响应验证我们的验签实现，可捕获 coverMap2String 的字段拍平规则
 * 与银行不一致的问题（那会导致整个渠道不可用，且只在联调时暴露）。
 */
class HccbKitTest {

    /** 测试环境银行签名证书标识 */
    private static final String BANK_CERT_ID = "H100001861";

    // ---------------------------------------------------------------- 报文拍平规则

    @Test
    @DisplayName("coverMap2String：按参数名 ASCII 升序拼接，排除 signAture")
    void coverMap2String_shouldSortAsciiAndExcludeSignature() {
        Map<String, Object> data = new HashMap<>();
        data.put("txnType", "1000");
        data.put("aesWay", "04");
        data.put("merId", "8202608105388480");
        data.put("signAture", "SHOULD_BE_EXCLUDED");
        data.put("certId", "17010100001");

        String actual = HccbKit.coverMap2String(data, false);

        assertEquals("aesWay=04&certId=17010100001&merId=8202608105388480&txnType=1000", actual);
        assertFalse(actual.contains("SHOULD_BE_EXCLUDED"), "签名域不得参与签名");
    }

    @Test
    @DisplayName("coverMap2String：null 一律跳过、空串保留——与 fastjson 序列化行为严格对齐")
    void coverMap2String_nullSkippedBlankKept() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("a", "1");
        data.put("b", "");      // 空串：报文中会出现 "b":""，签名也必须含 b=
        data.put("c", null);    // null：fastjson 不输出该键，签名也必须跳过

        // 加签（skipBlank=false）：null 跳过、空串保留
        assertEquals("a=1&b=", HccbKit.coverMap2String(data, false));
    }

    @Test
    @DisplayName("签名集必须等于发送集：null 值键两边都不出现（曾出现「签名含 k=null、报文无该键」）")
    void signFieldSet_mustMatchSerializedJson() {
        Map<String, Object> sent = new LinkedHashMap<>();
        sent.put("merId", "M1");
        sent.put("sdkAppId", null);   // 配置缺失时会出现的场景
        sent.put("txnAmt", "1");

        String signed = HccbKit.coverMap2String(sent, false);
        String json = com.alibaba.fastjson.JSON.toJSONString(sent);

        assertFalse(signed.contains("sdkAppId"), "签名含 null 字段，但报文中不会有该键 —— 银行验签会失败");
        assertFalse(json.contains("sdkAppId"), "前置假设变化：fastjson 现在会输出 null 键，需同步调整签名规则");
        assertEquals("merId=M1&txnAmt=1", signed);
    }

    // ---------------------------------------------------------------- 真实响应验签（关键回归）

    @Test
    @DisplayName("验签：真实银行响应应通过，且签名者证书被固定")
    void verify_realBankResponse() throws Exception {

        JSONObject resp = JSON.parseObject(readResource("/hccb/pay_response_real.json"));
        String signAture = resp.getString(HccbKit.SIGN_FIELD);

        assertNotNull(signAture, "测试资源应包含 signAture");
        assertEquals("0000", resp.getString("respCode"), "测试资源应为一次成功的下单响应");

        // 1) 验签通过 + 签名者证书匹配银行标识
        assertTrue(HccbKit.verify(resp, signAture, BANK_CERT_ID),
                "真实银行响应验签失败：coverMap2String 的拍平规则可能与银行不一致");

        // 2) 信任锚生效：签名者不是指定证书时必须拒绝
        assertFalse(HccbKit.verify(resp, signAture, "NOT_THE_BANK"),
                "签名者证书不匹配时仍返回 true —— 信任锚校验失效，可被伪造回调");
    }

    @Test
    @DisplayName("验签：bankCertId 未配置时必须拒绝（fail-closed，不得降级放行）")
    void verify_shouldFailClosedWhenSignerCertIdMissing() throws Exception {

        JSONObject resp = JSON.parseObject(readResource("/hccb/pay_response_real.json"));
        String signAture = resp.getString(HccbKit.SIGN_FIELD);

        // 若不配置签名者标识就放行，任何持有效 CFCA 证书者都能伪造回调
        assertFalse(HccbKit.verify(resp, signAture, null),
                "bankCertId 为空时验签仍然通过 —— 信任锚 fail-open，可被伪造");
        assertFalse(HccbKit.verify(resp, signAture, ""),
                "bankCertId 为空串时验签仍然通过 —— 信任锚 fail-open，可被伪造");
    }

    @Test
    @DisplayName("验签：签名被篡改应失败")
    void verify_tamperedPayloadShouldFail() throws Exception {

        JSONObject resp = JSON.parseObject(readResource("/hccb/pay_response_real.json"));
        String signAture = resp.getString(HccbKit.SIGN_FIELD);

        resp.put("respCode", "0000");
        resp.put("respMsg", "交易成功（被篡改）");

        assertFalse(HccbKit.verify(resp, signAture, BANK_CERT_ID),
                "报文体被篡改后验签仍然通过");
    }

    @Test
    @DisplayName("extractCashierUrl：txnTokenPayData 是 JSON 字符串，须能解出收银台地址")
    void extractCashierUrl_handlesJsonString() throws Exception {

        JSONObject resp = JSON.parseObject(readResource("/hccb/pay_response_real.json"));

        // 实测该字段是字符串而非嵌套对象；曾因直接 getJSONObject 取值而拿不到地址
        assertTrue(resp.get("txnTokenPayData") instanceof String,
                "测试资源形态变化，请复核 extractCashierUrl 的分支假设");

        String url = HccbKit.extractCashierUrl(resp);
        assertNotNull(url, "未能从真实响应中解出收银台地址");
        assertTrue(url.contains("uniCashierNew.html"), "收银台地址异常：" + url);
        assertTrue(url.contains("tokenCode="), "收银台地址缺少令牌：" + url);
    }

    @Test
    @DisplayName("extractCashierUrl：兼容嵌套对象形态与缺失字段")
    void extractCashierUrl_handlesObjectAndMissing() {
        JSONObject asObject = JSON.parseObject("{\"txnTokenPayData\":{\"tokenCodeURL\":\"https://x/y\"}}");
        assertEquals("https://x/y", HccbKit.extractCashierUrl(asObject));

        assertNull(HccbKit.extractCashierUrl(new JSONObject()));
        assertNull(HccbKit.extractCashierUrl(JSON.parseObject("{\"txnTokenPayData\":\"not-json\"}")));
    }

    // ---------------------------------------------------------------- 渠道参数

    @Test
    @DisplayName("deSenData：证书密码回显明文，且只输出配置字段")
    void deSenData_shouldEchoPlaintextAndExposeOnlyConfigFields() {
        HccbNormalMchParams cfg = new HccbNormalMchParams();
        cfg.setMerId("8202608105388480");
        cfg.setMchCertFile("cert/abc.pfx");
        cfg.setMchCertPwd("000000");

        String json = cfg.deSenData();

        // 证书密码回显明文（产品要求：编辑时不必重填）
        assertTrue(json.contains("\"mchCertPwd\":\"000000\""),
                "证书密码未回显，编辑时会被清空：" + json);

        // 回显字段集必须恰好是配置项，避免将来新增 getter/派生字段被反射序列化混入
        com.alibaba.fastjson.JSONObject obj = JSON.parseObject(json);
        java.util.Set<String> allowed = new java.util.HashSet<>(java.util.Arrays.asList(
                "merId", "certId", "bankCertId", "sdkAppId", "payUrl", "mchCertFile", "mchCertPwd"));
        // fastjson 跳过 null，故未赋值的配置项不出现——只断言"不含意料之外的字段"
        assertTrue(allowed.containsAll(obj.keySet()),
                "deSenData 回显了非配置字段：" + obj.keySet());
    }

    @Test
    @DisplayName("验签：真实银行回调报文应通过（异步通知链路的回归）")
    void verify_realBankNotify() throws Exception {

        JSONObject notify = JSON.parseObject(readResource("/hccb/notify_response_real.json"));
        String signAture = notify.getString(HccbKit.SIGN_FIELD);

        assertEquals("0000", notify.getString("respCode"), "测试资源应为一次成功的支付通知");
        assertEquals("00", notify.getString("orderStat"), "测试资源应为交易成功状态");
        assertNotNull(signAture);

        // 回调报文与下单响应字段集不同（多出 tpamTxnSsn/openId/wxOrderId 等），
        // 验签按全字段参与，此处验证我们对该形态同样能验通。
        assertTrue(HccbKit.verify(notify, signAture, BANK_CERT_ID),
                "真实银行回调验签失败：通知报文的字段拍平规则与下单响应不一致？");

        // 信任锚同样生效
        assertFalse(HccbKit.verify(notify, signAture, "NOT_THE_BANK"));
    }

    @Test
    @DisplayName("回调报文：真实形态含 orderStat / settleAmt（文档字段表与实际不符）")
    void realNotify_containsUndocumentedFields() throws Exception {
        JSONObject notify = JSON.parseObject(readResource("/hccb/notify_response_real.json"));

        // 这些是实测存在、但接口文档 2.1.5 未列的字段——
        // 实现若照文档写死字段会漏判
        for (String f : new String[]{"orderStat", "settleAmt", "tpamTxnSsn", "txnType", "respTxnSsn", "respTxnTime"}) {
            assertTrue(notify.containsKey(f), "真实回调缺少字段：" + f);
        }
        // 文档列了但实际不存在的字段
        for (String f : new String[]{"txnBankTransId", "remark", "resv"}) {
            assertFalse(notify.containsKey(f), "文档声称有但实测不存在的字段：" + f);
        }
    }

    // ---------------------------------------------------------------- 签名/发送一致性

    @Test
    @DisplayName("签名集必须等于发送集：空值字段也要参与签名")
    void signFieldSet_mustEqualSentFieldSet() {
        Map<String, Object> sent = new TreeMap<>();
        sent.put("merId", "8202608105388480");
        sent.put("resv", "");          // 空值：曾经「发送但不签名」，银行按全字段验签会失败
        sent.put("txnAmt", "1");

        String signed = HccbKit.coverMap2String(sent, false);

        assertEquals("merId=8202608105388480&resv=&txnAmt=1", signed,
                "空值字段未参与签名 —— 签名集与发送集分叉，银行验签会失败");
    }

    @Test
    @DisplayName("签名域 signAture 在任何情况下都不参与签名")
    void signFieldSet_neverIncludesSignatureField() {
        Map<String, Object> sent = new TreeMap<>();
        sent.put("merId", "M1");
        sent.put(HccbKit.SIGN_FIELD, "SHOULD_NOT_APPEAR");

        assertFalse(HccbKit.coverMap2String(sent, false).contains("SHOULD_NOT_APPEAR"));
    }

    // ---------------------------------------------------------------- 订单有效期门禁

    @Test
    @DisplayName("preCheck：有效期正好 30 分钟不得被拒（整数取整曾把 1800s 算成 29 分钟）")
    void preCheck_exactlyThirtyMinutesShouldPass() {
        PayOrder order = new PayOrder();
        order.setExpiredTime(new java.util.Date(System.currentTimeMillis() + HccbKit.CASHIER_TOKEN_MINUTES * 60_000L));
        assertNull(new HccbQr().preCheck(new UnifiedOrderRQ(), order),
                "有效期正好等于收银台令牌时长时被误拒");

        // 略少于 30 分钟才该拒
        PayOrder short_ = new PayOrder();
        short_.setExpiredTime(new java.util.Date(System.currentTimeMillis() + HccbKit.CASHIER_TOKEN_MINUTES * 60_000L - 5_000L));
        assertNotNull(new HccbQr().preCheck(new UnifiedOrderRQ(), short_),
                "有效期短于收银台令牌时长时未拦截");
    }

    // ---------------------------------------------------------------- 渠道注册约定

    @Test
    @DisplayName("payway 类名须与 wayCode 反射推导一致（不一致则 getBean 静默返回 null）")
    void paywayClassName_matchesWayCodeReflection() throws ClassNotFoundException {

        // PaywayUtil.getRealPaywayService 的推导规则：
        //   下划线转驼峰 + 首字母大写，再在 channel.{ifCode}.payway 下反射取类
        String wayCode = CS.PAY_WAY_CODE.HCCB_QR;
        String clsName = StrUtil.upperFirst(StrUtil.toCamelCase(wayCode.toLowerCase()));

        assertEquals("HccbQr", clsName, "wayCode 与 payway 类名的推导规则失配");
        // 类若不在此处会抛 ClassNotFoundException —— 该失败模式无编译期信号
        Class.forName("com.blue.whale.pay.pay.channel.hccb.payway." + clsName);
    }

    @Test
    @DisplayName("渠道 Bean 名须等于 ifCode + 固定后缀（不一致则 getBean 静默返回 null）")
    void serviceBeanNames_followConvention() {
        String ifCode = CS.IF_CODE.HCCB;
        assertEquals("hccb", ifCode, "Bean 名前缀来自 ifCode，改动会波及四个服务类名");
    }

    // ---------------------------------------------------------------- 跨请求回传数据

    @Test
    @DisplayName("buildResData / getResDataField 往返")
    void resData_roundTrip() {
        String json = HccbKit.buildResData("82026092010104934477806665402766", "20260920101049");

        assertEquals("82026092010104934477806665402766",
                HccbKit.getResDataField(json, "respTxnSsn"));
        assertEquals("20260920101049",
                HccbKit.getResDataField(json, "respTxnTime"));
    }

    @Test
    @DisplayName("getResDataField：null / 空 / 非法 JSON 均安全返回 null")
    void getResDataField_handlesBadInput() {
        assertNull(HccbKit.getResDataField(null, "respTxnSsn"));
        assertNull(HccbKit.getResDataField("", "respTxnSsn"));
        assertNull(HccbKit.getResDataField("not-a-json", "respTxnSsn"));
        assertNull(HccbKit.getResDataField("{}", "respTxnSsn"));
    }

    // ---------------------------------------------------------------- 查询流水号

    @Test
    @DisplayName("buildQueryOrderId：不超渠道 32 字符限制，且每次调用不重复")
    void buildQueryOrderId_shouldBeBoundedAndUnique() {
        String first = HccbKit.buildQueryOrderId();
        String second = HccbKit.buildQueryOrderId();

        assertTrue(first.length() <= 32, "查询流水号超出渠道 32 字符限制：" + first);
        assertTrue(second.length() <= 32, "查询流水号超出渠道 32 字符限制：" + second);
        // 轮询对同一订单反复查询；若流水号复用且银行做唯一性校验，第二次起会被拒 → 补单静默失效
        assertNotEquals(first, second, "轮询复用了同一查询流水号，可能导致补单静默失效");
    }

    // ----------------------------------------------------------------

    private String readResource(String path) throws Exception {
        try (InputStream in = getClass().getResourceAsStream(path)) {
            assertNotNull(in, "测试资源不存在：" + path);
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

}
