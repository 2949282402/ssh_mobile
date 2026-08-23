//! Bounded event-lane policy tests kept outside the production module.

use super::*;

fn control_event() -> NetworkEvent {
    NetworkEvent {
        payload: Some(network_event::Payload::PeerState(
            network_protocol::PeerStateChangedEvent::default(),
        )),
        ..Default::default()
    }
}

fn data_event() -> NetworkEvent {
    NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            network_protocol::ChannelMessageEvent {
                payload: vec![1, 2, 3],
                ..Default::default()
            },
        )),
        ..Default::default()
    }
}

#[tokio::test]
async fn releases_bytes_and_prefers_data_after_a_control_burst() {
    let (sender, mut receiver) = BoundedEventLanes::channel();
    let control = control_event();
    let data = data_event();

    for _ in 0..MAX_CONSECUTIVE_CONTROL_EVENTS {
        sender.send(control.clone()).expect("control event");
    }
    sender.send(data).expect("data event");
    for _ in 0..MAX_CONSECUTIVE_CONTROL_EVENTS {
        assert!(matches!(
            receiver.try_recv().and_then(|event| event.payload),
            Some(network_event::Payload::PeerState(_))
        ));
    }
    assert!(matches!(
        receiver.try_recv().and_then(|event| event.payload),
        Some(network_event::Payload::ChannelMessage(_))
    ));

    // Fill the byte budget before mailbox capacity, drain it, and prove the
    // released accounting admits the same payload again.
    let large_data = NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            network_protocol::ChannelMessageEvent {
                payload: vec![0; MAX_EVENT_BYTES / 2],
                ..Default::default()
            },
        )),
        ..Default::default()
    };
    let mut accepted = 0;
    while sender.send(large_data.clone()).is_ok() {
        accepted += 1;
    }
    assert!(accepted > 0);
    for _ in 0..accepted {
        assert!(receiver.try_recv().is_some());
    }
    sender
        .send(large_data)
        .expect("released byte budget accepts another event");
    assert!(receiver.try_recv().is_some());

    let oversized = NetworkEvent {
        payload: Some(network_event::Payload::ChannelMessage(
            network_protocol::ChannelMessageEvent {
                payload: vec![0; MAX_EVENT_BYTES],
                ..Default::default()
            },
        )),
        ..Default::default()
    };
    assert!(sender.send(oversized).is_err());
    drop(sender);
    assert!(receiver.recv().await.is_none());
}

#[tokio::test]
async fn handles_either_lane_closing_first() {
    let (sender, mut receiver) = BoundedEventLanes::channel();
    sender.send(data_event()).expect("data event");
    let EventSender::Bounded {
        control_sender,
        data_sender,
        ..
    } = sender
    else {
        panic!("production lane factory must return bounded sender");
    };
    drop(control_sender);
    drop(data_sender);
    assert!(matches!(
        receiver.recv().await.and_then(|event| event.payload),
        Some(network_event::Payload::ChannelMessage(_))
    ));
    assert!(receiver.recv().await.is_none());

    let (sender, mut receiver) = BoundedEventLanes::channel();
    sender.send(control_event()).expect("control event");
    let EventSender::Bounded {
        control_sender,
        data_sender,
        ..
    } = sender
    else {
        panic!("production lane factory must return bounded sender");
    };
    drop(data_sender);
    drop(control_sender);
    assert!(matches!(
        receiver.recv().await.and_then(|event| event.payload),
        Some(network_event::Payload::PeerState(_))
    ));
    assert!(receiver.recv().await.is_none());
}
