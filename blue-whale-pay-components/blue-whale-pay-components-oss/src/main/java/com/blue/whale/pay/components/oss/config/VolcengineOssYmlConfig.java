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
package com.blue.whale.pay.components.oss.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 火山引擎 TOS 的 yml 配置参数（prefix = isys.oss.volcengine-tos）
 *
 * @author blue-whale
 * @date 2026/07/28
 */
@Data
@Component
@ConfigurationProperties(prefix="isys.oss.volcengine-tos")
public class VolcengineOssYmlConfig {

	/** endpoint，如 https://tos-cn-beijing.volces.com **/
	private String endpoint;

	/** region，如 cn-beijing **/
	private String region;

	/** 公共读桶名（商户图标、接口背景图等） **/
	private String publicBucketName;

	/** 私有桶名（支付渠道证书等） **/
	private String privateBucketName;

	/** AccessKey（生产建议走环境变量注入） **/
	private String accessKey;

	/** SecretKey（生产建议走环境变量注入） **/
	private String secretKey;

	/** 公共访问域名，如 https://sweet-oa.tos-cn-beijing.volces.com **/
	private String domain;

	/** 存储路径前缀，用于在同一桶内隔离业务文件，如 bluewhale-pay **/
	private String prefix;
}
