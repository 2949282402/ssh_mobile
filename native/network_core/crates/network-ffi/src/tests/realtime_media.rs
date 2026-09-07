use super::*;
use std::ptr;

const REALTIME_ID: &[u8] = b"00112233445566778899aabbccddeeff";
const PEER_ID: &[u8] = b"peer-a";

#[test]
fn media_endpoint_ffi_is_payload_free_and_enforces_runtime_lifecycle() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);

    let mut endpoint = 99_u64;
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_create(
                handle,
                REALTIME_ID.as_ptr(),
                REALTIME_ID.len(),
                PEER_ID.as_ptr(),
                PEER_ID.len(),
                crate::realtime_media::SSH_NET_REALTIME_MEDIA_DIRECTION_SEND,
                &mut endpoint,
            )
        },
        -2,
    );
    assert_eq!(endpoint, 0);
    assert_eq!(
        unsafe { crate::realtime_media::ssh_net_realtime_media_endpoint_release(handle, 0) },
        -1,
    );

    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_create(
                handle,
                REALTIME_ID.as_ptr(),
                REALTIME_ID.len(),
                PEER_ID.as_ptr(),
                PEER_ID.len(),
                crate::realtime_media::SSH_NET_REALTIME_MEDIA_DIRECTION_SEND,
                &mut endpoint,
            )
        },
        -4,
    );
    assert_eq!(
        unsafe { crate::realtime_media::ssh_net_realtime_media_endpoint_release(handle, 42) },
        0,
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}

#[test]
fn native_h264_bridge_rejects_unknown_or_stopped_endpoint_without_returning_media() {
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { ssh_net_runtime_create(&mut handle) }, 0);
    assert_eq!(unsafe { ssh_net_runtime_start(handle) }, 0);

    let metadata = crate::realtime_media::SshNetRealtimeMediaFrameMetadata {
        sequence: 1,
        timestamp: 90_000,
        width: 1280,
        height: 720,
        keyframe: 1,
    };
    let payload = [0, 0, 0, 1, 0x65];
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_push_h264(
                handle,
                42,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        -2,
    );

    let mut returned_metadata = Default::default();
    let mut returned_payload = SshNetBuffer {
        ptr: ptr::null_mut(),
        len: 99,
    };
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_pull_h264(
                handle,
                42,
                &mut returned_metadata,
                &mut returned_payload,
            )
        },
        -2,
    );
    assert!(returned_payload.ptr.is_null());
    assert_eq!(returned_payload.len, 0);

    assert_eq!(unsafe { ssh_net_runtime_stop(handle) }, 0);
    assert_eq!(
        unsafe {
            crate::realtime_media::ssh_net_realtime_media_endpoint_push_h264(
                handle,
                42,
                metadata,
                payload.as_ptr(),
                payload.len(),
            )
        },
        -4,
    );
    assert_eq!(unsafe { ssh_net_runtime_destroy(handle) }, 0);
}
