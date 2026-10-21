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
package com.blue.whale.pay.core.model.params.hccb;

import com.alibaba.fastjson.JSONObject;
import com.blue.whale.pay.core.model.params.NormalMchParams;
import lombok.Data;

/*
 * 杭州银行线上支付平台 普通商户参数定义
 *
 * @site https://www.hzbank.com.cn
 */
@Data
public class HccbNormalMchParams extends NormalMchParams {

    /** 商户编号 */
    private String merId;

    /** 证书ID（与银行侧验签平台登记的商户证书对应） */
    private String certId;

    /**
     * 银行签名证书标识（信任锚）。
     *
     * 银行响应/回调的 PKCS7 签名内嵌其证书，验签必须校验签名者确为银行，
     * 否则任何持有效 CFCA 证书者都能伪造报文。测试环境为 H100001861。
     */
    private String bankCertId;

    /** 版本号 / appId */
    private String sdkAppId;

    /** 支付网关地址 */
    private String payUrl;

    /** 商户证书文件名（.pfx，由配置页以 bizType=cert 上传，存于 OSS 私有目录） */
    private String mchCertFile;

    /** 商户证书密码 */
    private String mchCertPwd;

    /**
     * 渠道参数回显。
     *
     * 证书密码按产品要求**回显明文**（便于编辑时不重填），不做脱敏。
     * 其余字段原样返回。
     */
    @Override
    public String deSenData() {
        return JSONObject.toJSONString(this);
    }

}
