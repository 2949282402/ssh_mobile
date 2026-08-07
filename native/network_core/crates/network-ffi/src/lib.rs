//! v1 C ABI 绑定：负责 network-core 运行时创建、命令、轮询和确定性生命周期控制。
#![allow(linker_messages)]

use network_core::NetworkRuntime;
use network_protocol::NetworkCommand;
use prost::Message;
use std::ffi::c_void;
use std::panic::catch_unwind;
use std::slice;

pub const SSH_NET_ABI_VERSION: u32 = 1;

/// 跨 FFI 边界传递的不透明运行时句柄。
pub type SshNetRuntimeHandle = *mut c_void;

#[repr(C)]
pub struct SshNetBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

/// 返回当前 ABI 版本号。
#[no_mangle]
pub extern "C" fn ssh_net_abi_version() -> u32 {
    SSH_NET_ABI_VERSION
}

/// 创建新的 NetworkRuntime 实例。
/// 成功返回 0，失败返回负错误码。
/// 输出句柄写入 `out_handle`。
///
/// # Safety
/// `out_handle` 必须是有效且非空、可接收运行时句柄的指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_create(out_handle: *mut SshNetRuntimeHandle) -> i32 {
    if out_handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| match NetworkRuntime::new() {
        Ok(runtime) => {
            let boxed = Box::new(runtime);
            let raw = Box::into_raw(boxed) as SshNetRuntimeHandle;
            unsafe {
                *out_handle = raw;
            }
            0
        }
        Err(_) => -2,
    });

    result.unwrap_or(-99)
}

/// 启动/激活网络运行时操作。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_start(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const NetworkRuntime) };
        match runtime.start() {
            Ok(()) => 0,
            Err(_) => -3,
        }
    });

    result.unwrap_or(-99)
}

/// 停止运行时 worker。停止操作幂等，销毁句柄前必须调用。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_stop(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const NetworkRuntime) };
        match runtime.stop() {
            Ok(()) => 0,
            Err(_) => -3,
        }
    });

    result.unwrap_or(-99)
}

/// 向运行时 worker 发送 Protobuf 编码的 NetworkCommand。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是有效运行时句柄。
/// `command_ptr` 必须指向 `command_len` 个编码 Protobuf 消息字节。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_command(
    handle: SshNetRuntimeHandle,
    command_ptr: *const u8,
    command_len: usize,
) -> i32 {
    if handle.is_null() || command_ptr.is_null() || command_len == 0 {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const NetworkRuntime) };
        let slice = unsafe { slice::from_raw_parts(command_ptr, command_len) };

        match NetworkCommand::decode(slice) {
            Ok(cmd) => match runtime.send_command(cmd) {
                Ok(_) => 0,
                Err(network_core::NetworkError::RuntimeNotRunning) => -4,
                Err(_) => -3,
            },
            Err(_) => -2,
        }
    });

    result.unwrap_or(-99)
}

/// 按超时轮询下一个 NetworkEvent。
/// 若有事件，将其序列化为 Protobuf 并写入 `out_event`。
/// 填充事件返回 1，超时或无事件返回 0，错误返回负值。
///
/// # Safety
/// 当 `out_event.ptr` 非空时，调用方必须使用 `ssh_net_buffer_free` 释放它。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_poll_event(
    handle: SshNetRuntimeHandle,
    timeout_ms: u32,
    out_event: *mut SshNetBuffer,
) -> i32 {
    if handle.is_null() || out_event.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const NetworkRuntime) };
        unsafe {
            (*out_event).ptr = std::ptr::null_mut();
            (*out_event).len = 0;
        }

        if let Some(event) = runtime.poll_event(timeout_ms) {
            let mut encoded = Vec::new();
            if event.encode(&mut encoded).is_ok() {
                let len = encoded.len();
                let mut boxed_slice = encoded.into_boxed_slice();
                let ptr = boxed_slice.as_mut_ptr();
                std::mem::forget(boxed_slice);

                unsafe {
                    (*out_event).ptr = ptr;
                    (*out_event).len = len;
                }
                return 1;
            }
        }
        0
    });

    result.unwrap_or(-99)
}

/// 释放由 Rust FFI 分配的缓冲区（例如 `ssh_net_runtime_poll_event` 返回的缓冲区）。
///
/// # Safety
/// `buffer.ptr` 必须来自 Rust FFI，释放后不得继续使用。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_buffer_free(buffer: SshNetBuffer) {
    if !buffer.ptr.is_null() && buffer.len > 0 {
        let _ = unsafe { Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.len) };
    }
}

/// 销毁 NetworkRuntime 实例并释放关联内存。
/// 成功返回 0，失败返回负错误码。
///
/// # Safety
/// `handle` 必须是由 `ssh_net_runtime_create` 创建的有效指针，调用后不得继续使用。
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_destroy(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        unsafe {
            let runtime = Box::from_raw(handle as *mut NetworkRuntime);
            let _ = runtime.stop();
        }
        0
    });

    result.unwrap_or(-99)
}

#[cfg(test)]
mod tests {
    use super::*;
    use network_protocol::NetworkCommand;
    use prost::Message;
    use std::ptr;

    /// 验证 v1 FFI 对空句柄和空 buffer 的确定性拒绝。
    #[test]
    fn rejects_invalid_buffers_without_panicking() {
        assert_eq!(unsafe { ssh_net_runtime_create(ptr::null_mut()) }, -1);
        assert_eq!(unsafe { ssh_net_runtime_start(ptr::null_mut()) }, -1);
        assert_eq!(unsafe { ssh_net_runtime_stop(ptr::null_mut()) }, -1);
        assert_eq!(
            unsafe { ssh_net_runtime_command(ptr::null_mut(), ptr::null(), 0) },
            -1
        );
        assert_eq!(
            unsafe { ssh_net_runtime_poll_event(ptr::null_mut(), 1, ptr::null_mut()) },
            -1
        );
        unsafe {
            ssh_net_buffer_free(SshNetBuffer {
                ptr: ptr::null_mut(),
                len: 0,
            });
        }
    }

    /// 验证 v1 运行时的创建、启动、重复停止、停止后命令和销毁顺序。
    #[test]
    fn enforces_runtime_lifecycle_order() {
        let mut handle = ptr::null_mut();
        assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
        assert!(!handle.is_null());
        assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);
        assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
        assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
        let command = NetworkCommand {
            command_id: "stopped-command".to_string(),
            protocol_version: network_protocol::NETWORK_PROTOCOL_VERSION,
            payload: None,
        }
        .encode_to_vec();
        assert_eq!(
            unsafe { ssh_net_runtime_command(handle, command.as_ptr(), command.len()) },
            -4
        );
        assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
    }
}
