#ifndef SSH_MOBILE_QUIC_NATIVE_H
#define SSH_MOBILE_QUIC_NATIVE_H

#include <stdint.h>

/*
 * Windows DLL 导出符号需要 __declspec(dllexport)。
 *
 * Android/Linux 使用 visibility("default")，
 * 保证这个函数可以从生成出来的 .so 中被 Dart FFI 找到。
 */
#if defined(_WIN32)
#define SSH_QUIC_EXPORT __declspec(dllexport)
#else
#define SSH_QUIC_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * 最基础的 FFI 测试函数。
 *
 * 它现在完全不调用 MsQuic。
 * 单纯用于验证：
 *
 * Dart -> Native library -> C function
 *
 * 这条链路是否成立。
 */
SSH_QUIC_EXPORT int32_t ssh_quic_ping(void);

#ifdef __cplusplus
}
#endif

#endif