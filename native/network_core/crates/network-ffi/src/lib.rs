//! C ABI FFI bindings for network-core.

use std::ffi::c_void;
use std::panic::catch_unwind;
use network_core::NetworkRuntime;

pub const SSH_NET_ABI_VERSION: u32 = 1;

/// Opaque runtime handle passed across FFI boundary.
pub type SshNetRuntimeHandle = *mut c_void;

/// Returns the current ABI version number.
#[no_mangle]
pub extern "C" fn ssh_net_abi_version() -> u32 {
    SSH_NET_ABI_VERSION
}

/// Returns SDK version marker (replaces legacy ssh_quic_ping).
#[no_mangle]
pub extern "C" fn ssh_net_sdk_version() -> u32 {
    100
}

/// Creates a new NetworkRuntime instance.
/// Returns 0 on success, negative error code on failure.
/// Output handle is written to `out_handle`.
///
/// # Safety
/// `out_handle` must be a valid, non-null pointer to receive the runtime handle.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_create(out_handle: *mut SshNetRuntimeHandle) -> i32 {
    if out_handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        match NetworkRuntime::new() {
            Ok(runtime) => {
                let boxed = Box::new(runtime);
                let raw = Box::into_raw(boxed) as SshNetRuntimeHandle;
                unsafe {
                    *out_handle = raw;
                }
                0
            }
            Err(_) => -2,
        }
    });

    result.unwrap_or(-99)
}

/// Starts/activates the network runtime operations.
/// Returns 0 on success, negative error code on failure.
///
/// # Safety
/// `handle` must be a valid pointer created by `ssh_net_runtime_create`.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_start(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        let runtime = unsafe { &*(handle as *const NetworkRuntime) };
        let _handle = runtime.handle();
        0
    });

    result.unwrap_or(-99)
}

/// Destroys the NetworkRuntime instance and frees associated memory.
/// Returns 0 on success, negative error code on failure.
///
/// # Safety
/// `handle` must be a valid pointer created by `ssh_net_runtime_create`, and must not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_runtime_destroy(handle: SshNetRuntimeHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }

    let result = catch_unwind(|| {
        unsafe {
            let _ = Box::from_raw(handle as *mut NetworkRuntime);
        }
        0
    });

    result.unwrap_or(-99)
}
