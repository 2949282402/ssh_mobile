use super::*;
use crate::connection::{ConnectionProfile, Route, RouteTransport};

#[test]
fn communication_class_maps_to_capability_bits_per_design_17() {
    assert_eq!(
        communication_class_capability(CommunicationClass::ReliableMessage),
        CAPABILITY_RELIABLE_MESSAGE
    );
    assert_eq!(
        communication_class_capability(CommunicationClass::ReliableStream),
        CAPABILITY_RELIABLE_STREAM
    );
    assert_eq!(
        communication_class_capability(CommunicationClass::BulkTransfer),
        CAPABILITY_RELIABLE_STREAM
    );
    assert_eq!(
        communication_class_capability(CommunicationClass::UnreliableDatagram),
        CAPABILITY_UNRELIABLE_DATAGRAM
    );
    // RealtimeMedia 不经过普通 ConnectionSession 建连；映射到基线安全值。
    assert_eq!(
        communication_class_capability(CommunicationClass::RealtimeMedia),
        DEFAULT_CONNECTION_CAPABILITY
    );
    // 旧调用方（Unspecified/0）按默认 ReliableMessage。
    assert_eq!(
        default_communication_class(CommunicationClass::Unspecified),
        CommunicationClass::ReliableMessage
    );
}

#[test]
fn profile_capability_mask_records_what_a_route_actually_carries() {
    // QUIC carries messages + streams + datagrams.
    let quic = ConnectionProfile::new(Route::direct(RouteTransport::Quic));
    assert_eq!(
        profile_capability_mask(quic),
        DEFAULT_CONNECTION_CAPABILITY | CAPABILITY_UNRELIABLE_DATAGRAM
    );
    let tcp = ConnectionProfile::new(Route::direct(RouteTransport::Tcp));
    assert_eq!(profile_capability_mask(tcp), DEFAULT_CONNECTION_CAPABILITY);
    let ws = ConnectionProfile::new(Route::direct(RouteTransport::WebSocket));
    assert_eq!(profile_capability_mask(ws), CAPABILITY_RELIABLE_MESSAGE);
    // Relay Stream fallback（§17）：Relay 数据面透明转发字节流。
    let relay = ConnectionProfile::new(Route::relay(RouteTransport::WebSocket));
    assert_eq!(
        profile_capability_mask(relay),
        DEFAULT_CONNECTION_CAPABILITY
    );
}
