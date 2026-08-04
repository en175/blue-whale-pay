package com.blue.whale.pay.mgr.service;

import com.blue.whale.pay.core.constants.CS;
import com.blue.whale.pay.core.service.ICodeSysTypeManager;
import org.springframework.stereotype.Component;

@Component
public class CodeSysTypeManager implements ICodeSysTypeManager {

    @Override
    public String getCodeSysName() {
        return CS.CODE_SYS_NAME_SET.JEEPAY_MANAGER;
    }
}
