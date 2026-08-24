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

fn result_event(command_id: &str) -> NetworkEvent {
    NetworkEvent {
        payload: Some(network_event::Payload::CommandResultV2(
            network_protocol::CommandResult {
                command_id: command_id.to_string(),
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

    for _ in 0..CONTROL_EVENT_BURST {
        sender.send(control.clone()).expect("control event");
    }
    sender.send(data).expect("data event");
    for _ in 0..CONTROL_EVENT_BURST {
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
        result_sender,
        control_sender,
        data_sender,
        ..
    } = sender
    else {
        panic!("production lane factory must return bounded sender");
    };
    drop(result_sender);
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
        result_sender,
        control_sender,
        data_sender,
        ..
    } = sender
    else {
        panic!("production lane factory must return bounded sender");
    };
    drop(result_sender);
    drop(data_sender);
    drop(control_sender);
    assert!(matches!(
        receiver.recv().await.and_then(|event| event.payload),
        Some(network_event::Payload::PeerState(_))
    ));
    assert!(receiver.recv().await.is_none());
}

#[tokio::test]
async fn result_lane_backpressures_and_three_lane_schedule_is_fair() {
    let (sender, mut receiver) = BoundedEventLanes::channel();
    for index in 0..RESULT_EVENT_MAILBOX_CAPACITY {
        sender
            .send_result(result_event(&format!("result-{index}")))
            .await
            .expect("result event");
    }
    let waiting_sender = sender.clone();
    let waiting = tokio::spawn(async move {
        waiting_sender
            .send_result(result_event("result-waiting"))
            .await
    });
    tokio::task::yield_now().await;
    assert!(!waiting.is_finished(), "full result lane must backpressure");
    assert!(matches!(
        receiver.try_recv().and_then(|event| event.payload),
        Some(network_event::Payload::CommandResultV2(_))
    ));
    waiting
        .await
        .expect("result sender joins")
        .expect("released result capacity");

    while receiver.try_recv().is_some() {}
    for index in 0..RESULT_EVENT_BURST {
        sender
            .send_result(result_event(&format!("fair-result-{index}")))
            .await
            .expect("result event");
    }
    for _ in 0..CONTROL_EVENT_BURST {
        sender.send(control_event()).expect("control event");
    }
    sender.send(data_event()).expect("data event");

    for _ in 0..RESULT_EVENT_BURST {
        assert!(matches!(
            receiver.try_recv().and_then(|event| event.payload),
            Some(network_event::Payload::CommandResultV2(_))
        ));
    }
    for _ in 0..CONTROL_EVENT_BURST {
        assert!(matches!(
            receiver.try_recv().and_then(|event| event.payload),
            Some(network_event::Payload::PeerState(_))
        ));
    }
    assert!(matches!(
        receiver.try_recv().and_then(|event| event.payload),
        Some(network_event::Payload::ChannelMessage(_))
    ));
}

#[tokio::test]
async fn full_control_lane_cannot_drop_a_terminal_result() {
    let (sender, mut receiver) = BoundedEventLanes::channel();
    for _ in 0..CONTROL_EVENT_MAILBOX_CAPACITY {
        sender.send(control_event()).expect("control event");
    }
    sender
        .send_result(result_event("terminal"))
        .await
        .expect("independent result lane");

    assert!(matches!(
        receiver.try_recv().and_then(|event| event.payload),
        Some(network_event::Payload::CommandResultV2(result))
            if result.command_id == "terminal"
    ));
}

#[test]
fn cancelled_byte_reservation_releases_its_budget() {
    let counter = Arc::new(AtomicUsize::new(0));
    let released = Arc::new(Notify::new());
    {
        let _reservation =
            QueuedByteReservation::try_new(Arc::clone(&counter), 128, 128, Some(released))
                .expect("byte reservation");
        assert_eq!(counter.load(Ordering::Acquire), 128);
    }
    assert_eq!(counter.load(Ordering::Acquire), 0);
}
