//! C ABI FFI bindings for network-core.
#![allow(linker_messages)]

use network_core::NetworkRuntime;
use network_protocol::NetworkCommand;
use prost::Message;
use std::ffi::c_void;
use std::panic::catch_unwind;
use std::slice;

pub const SSH_NET_ABI_VERSION: u32 = 1;

/// Opaque runtime handle passed across FFI boundary.
pub type SshNetRuntimeHandle = *mut c_void;

#[repr(C)]
pub struct SshNetBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

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

/// Sends a Protobuf encoded NetworkCommand to the runtime worker.
/// Returns 0 on success, negative error code on failure.
///
/// # Safety
/// `handle` must be a valid runtime handle.
/// `command_ptr` must point to `command_len` bytes of encoded Protobuf message.
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
                Err(_) => -3,
            },
            Err(_) => -2,
        }
    });

    result.unwrap_or(-99)
}

/// Polls for the next NetworkEvent with timeout.
/// If an event is available, serializes it to Protobuf and populates `out_event`.
/// Returns 1 if event populated, 0 if timeout/no event, negative on error.
///
/// # Safety
/// Caller MUST free `out_event.ptr` by calling `ssh_net_buffer_free` when `out_event.ptr` is non-null.
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

/// Frees a buffer allocated by Rust FFI (e.g., from `ssh_net_runtime_poll_event`).
///
/// # Safety
/// `buffer.ptr` must come from Rust FFI and must not be used after free.
#[no_mangle]
pub unsafe extern "C" fn ssh_net_buffer_free(buffer: SshNetBuffer) {
    if !buffer.ptr.is_null() && buffer.len > 0 {
        let _ = unsafe { Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.len) };
    }
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
