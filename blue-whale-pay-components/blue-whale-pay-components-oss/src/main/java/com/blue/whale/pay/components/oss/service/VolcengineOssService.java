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
package com.blue.whale.pay.components.oss.service;

import com.blue.whale.pay.components.oss.config.VolcengineOssYmlConfig;
import com.blue.whale.pay.components.oss.constant.OssSavePlaceEnum;
import com.volcengine.tos.TOSV2;
import com.volcengine.tos.TOSV2ClientBuilder;
import com.volcengine.tos.model.object.GetObjectV2Input;
import com.volcengine.tos.model.object.GetObjectV2Output;
import com.volcengine.tos.model.object.PutObjectInput;
import jakarta.annotation.PostConstruct;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/**
 * 火山引擎 TOS 实现类
 *
 * @author blue-whale
 * @date 2026/07/28
 */
@Service
@Slf4j
@ConditionalOnProperty(name = "isys.oss.service-type", havingValue = "volc-tos")
public class VolcengineOssService implements IOssService{

    @Autowired private VolcengineOssYmlConfig volcengineOssYmlConfig;

    // tosClient 初始化
    private TOSV2 tosClient = null;

    @PostConstruct
    public void init(){
        tosClient = new TOSV2ClientBuilder().build(
                volcengineOssYmlConfig.getRegion(),
                volcengineOssYmlConfig.getEndpoint(),
                volcengineOssYmlConfig.getAccessKey(),
                volcengineOssYmlConfig.getSecretKey()
        );
    }

    @Override
    public String upload2PreviewUrl(OssSavePlaceEnum ossSavePlaceEnum, MultipartFile multipartFile, String saveDirAndFileName) {

        try {

            String bucket = bucketOf(ossSavePlaceEnum);
            String key = fullKey(ossSavePlaceEnum, saveDirAndFileName);

            this.tosClient.putObject(new PutObjectInput()
                    .setBucket(bucket)
                    .setKey(key)
                    .setContent(multipartFile.getInputStream()));

            if(ossSavePlaceEnum == OssSavePlaceEnum.PUBLIC){
                return domain() + "/" + key;
            }
            return saveDirAndFileName;

        } catch (Exception e) {
            log.error("error", e);
            return null;
        }
    }

    @Override
    public boolean downloadFile(OssSavePlaceEnum ossSavePlaceEnum, String source, String target) {

        try {

            String bucket = bucketOf(ossSavePlaceEnum);
            String key = fullKey(ossSavePlaceEnum, source);

            try (GetObjectV2Output output = this.tosClient.getObject(new GetObjectV2Input().setBucket(bucket).setKey(key))) {
                File targetFile = new File(target);
                File parent = targetFile.getParentFile();
                if(parent != null && !parent.exists()){
                    parent.mkdirs();
                }
                Files.copy(output.getContent(), targetFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }

            return true;
        } catch (Exception e) {
            log.error("error", e);
            return false;
        }
    }

    /** 桶名：PRIVATE 用私有桶，PUBLIC 用公共桶 **/
    private String bucketOf(OssSavePlaceEnum ossSavePlaceEnum){
        return ossSavePlaceEnum == OssSavePlaceEnum.PRIVATE ? volcengineOssYmlConfig.getPrivateBucketName() : volcengineOssYmlConfig.getPublicBucketName();
    }

    /** 完整 key：{prefix}/{public|private}/{path}，prefix 用于在同一桶内隔离业务文件 **/
    private String fullKey(OssSavePlaceEnum ossSavePlaceEnum, String path){
        String placeDir = ossSavePlaceEnum == OssSavePlaceEnum.PUBLIC ? "public" : "private";
        String prefix = trimSlash(volcengineOssYmlConfig.getPrefix());
        return prefix.isEmpty() ? placeDir + "/" + path : prefix + "/" + placeDir + "/" + path;
    }

    /** 公共访问域名（去首尾斜杠） **/
    private String domain(){
        return trimEndSlash(volcengineOssYmlConfig.getDomain());
    }

    private static String trimSlash(String s){
        if(s == null){
            return "";
        }
        String r = s.trim();
        while(r.startsWith("/")){
            r = r.substring(1);
        }
        while(r.endsWith("/")){
            r = r.substring(0, r.length() - 1);
        }
        return r;
    }

    private static String trimEndSlash(String s){
        if(s == null){
            return "";
        }
        String r = s.trim();
        while(r.endsWith("/")){
            r = r.substring(0, r.length() - 1);
        }
        return r;
    }
}
