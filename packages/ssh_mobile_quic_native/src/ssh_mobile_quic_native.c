#include "ssh_mobile_quic_native.h"

int32_t ssh_quic_ping(void) {
    return 20260727;
}

int32_t ssh_quic_msquic_open_test(void) {

    /*
     * QUIC_API_TABLE 是 MsQuic 的核心函数表。
     *
     * 后面所有：
     *
     * RegistrationOpen
     * ConfigurationOpen
     * ConnectionOpen
     * StreamOpen
     * StreamSend
     *
     * 都是从这张 table 调用。
     */
    const QUIC_API_TABLE* api = NULL;

    /*
     * 初始化 MsQuic，
     * 获取 Version 2 API table。
     */
    const QUIC_STATUS status =
        MsQuicOpen2(&api);

    /*
     * QUIC_FAILED 是 MsQuic 提供的状态判断宏。
     */
    if (QUIC_FAILED(status)) {
        return 1;
    }

    /*
     * 理论上成功不应该得到 NULL，
     * 但我们的 wrapper 做防御性检查。
     */
    if (api == NULL) {

        /*
         * MsQuicOpen2 已经成功，
         * 所以仍然必须 close。
         *
         * 不过正常情况下不会走到这里。
         */
        return 2;
    }

    /*
     * 当前只是测试。
     *
     * 暂时不创建：
     *
     * Registration
     * Configuration
     * Connection
     *
     * 所以直接释放 API table。
     */
    MsQuicClose(api);

    return 0;
}