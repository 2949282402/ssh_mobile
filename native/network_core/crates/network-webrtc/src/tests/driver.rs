use super::*;
use crate::{DataChannelReliability, IceServerConfig, WebRtcConfig};
use std::time::Duration;
use tokio::sync::mpsc::channel;

#[tokio::test]
async fn two_local_drivers_exchange_data_channel_payloads() {
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    let channel_id = caller
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("local-e2e", DataChannelReliability::default())
        .expect("data channel");
    let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
    let answer = {
        let mut responder_driver = responder.lock().unwrap();
        responder_driver
            .peer_mut()
            .accept_remote_offer(offer)
            .unwrap();
        responder_driver.peer_mut().create_answer().unwrap()
    };
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .accept_remote_answer(answer)
        .unwrap();

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_open = false;
    let mut responder_open = false;
    let open_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !(caller_open && responder_open) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                caller_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            Some(event) = responder_events_rx.recv() => {
                responder_open |= matches!(event, RealtimeIoEvent::DataChannelOpened(_));
                assert!(!matches!(event, RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed));
            }
            _ = tokio::time::sleep_until(open_deadline) => panic!("data channel did not open"),
        }
    }

    caller
        .lock()
        .unwrap()
        .peer_mut()
        .send_data(channel_id, b"encoded-frame")
        .unwrap();
    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let payload = loop {
        tokio::select! {
            Some(event) = responder_events_rx.recv() => {
                if let RealtimeIoEvent::DataChannelMessage { payload, .. } = event {
                    break payload;
                }
            }
            _ = tokio::time::sleep_until(payload_deadline) => panic!("data channel payload not received"),
        }
    };
    assert_eq!(payload, b"encoded-frame");

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}

#[tokio::test]
async fn driver_bind_uses_explicit_advertised_ip_and_closes_cleanly() {
    let driver = RealtimeIoDriver::bind_with_advertised_ip(
        WebRtcPeer::new(WebRtcConfig::default()).expect("peer"),
        "127.0.0.1:0".parse().unwrap(),
        Some("192.0.2.44".parse().unwrap()),
    )
    .await
    .expect("driver");
    assert_eq!(
        driver.local_addr().ip(),
        "127.0.0.1".parse::<std::net::IpAddr>().unwrap()
    );
    let handle = driver.into_handle();
    let mut driver = handle.lock().unwrap();
    driver.peer_mut().create_offer().expect("offer");
    driver.close().expect("close");
}

#[tokio::test]
async fn unspecified_bind_advertises_loopback_as_safe_fallback() {
    let mut driver = RealtimeIoDriver::bind(
        WebRtcPeer::new(WebRtcConfig::default()).expect("peer"),
        "0.0.0.0:0".parse().unwrap(),
    )
    .await
    .expect("driver");
    driver.peer_mut().create_offer().expect("offer");
    driver.close().expect("close");
}

#[tokio::test]
#[ignore = "requires a local coturn server at 127.0.0.1:3478"]
async fn relay_only_drivers_exchange_data_channel_payloads() {
    let config = WebRtcConfig {
        ice_servers: vec![IceServerConfig::turn(
            "turn:127.0.0.1:3478?transport=udp",
            "test",
            "test",
        )],
        relay_only: true,
        ..Default::default()
    };
    let caller = RealtimeIoDriver::bind(
        WebRtcPeer::new(config.clone()).expect("caller peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("caller driver");
    let responder = RealtimeIoDriver::bind(
        WebRtcPeer::new(config).expect("responder peer"),
        "127.0.0.1:0".parse().unwrap(),
    )
    .await
    .expect("responder driver");

    let caller = Arc::new(Mutex::new(caller));
    let responder = Arc::new(Mutex::new(responder));
    let channel_id = caller
        .lock()
        .unwrap()
        .peer_mut()
        .create_data_channel("relay-e2e", DataChannelReliability::default())
        .expect("data channel");
    let offer = caller.lock().unwrap().peer_mut().create_offer().unwrap();
    let answer = {
        let mut responder_driver = responder.lock().unwrap();
        responder_driver
            .peer_mut()
            .accept_remote_offer(offer)
            .unwrap();
        responder_driver.peer_mut().create_answer().unwrap()
    };
    caller
        .lock()
        .unwrap()
        .peer_mut()
        .accept_remote_answer(answer)
        .unwrap();

    let (caller_events_tx, mut caller_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let (responder_events_tx, mut responder_events_rx) = channel(REALTIME_IO_EVENT_CAPACITY);
    let caller_task = tokio::spawn(run_realtime_io(Arc::clone(&caller), caller_events_tx));
    let responder_task = tokio::spawn(run_realtime_io(Arc::clone(&responder), responder_events_tx));

    let mut caller_open = false;
    let mut responder_open = false;
    let open_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !(caller_open && responder_open) {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelOpened(_) => caller_open = true,
                    RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("caller relay ICE failed"),
                    _ => {}
                }
            }
            Some(event) = responder_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelOpened(_) => responder_open = true,
                    RealtimeIoEvent::PeerFailed | RealtimeIoEvent::IceFailed => panic!("responder relay ICE failed"),
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(open_deadline) => panic!("TURN data channel did not open"),
        }
    }

    caller
        .lock()
        .unwrap()
        .peer_mut()
        .send_data(channel_id, b"turn-relay-frame")
        .unwrap();
    let payload_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let payload = loop {
        tokio::select! {
            Some(event) = caller_events_rx.recv() => {
                if let RealtimeIoEvent::LocalIceCandidate(candidate) = event {
                    responder.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                }
            }
            Some(event) = responder_events_rx.recv() => {
                match event {
                    RealtimeIoEvent::LocalIceCandidate(candidate) => {
                        caller.lock().unwrap().peer_mut().add_remote_ice_candidate(candidate).unwrap();
                    }
                    RealtimeIoEvent::DataChannelMessage { payload, .. } => break payload,
                    _ => {}
                }
            }
            _ = tokio::time::sleep_until(payload_deadline) => panic!("TURN data channel payload not received"),
        }
    };
    assert_eq!(payload, b"turn-relay-frame");

    caller_task.abort();
    responder_task.abort();
    let _ = caller_task.await;
    let _ = responder_task.await;
}
