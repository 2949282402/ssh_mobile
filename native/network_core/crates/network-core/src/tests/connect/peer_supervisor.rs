use super::*;

fn supervisor() -> Arc<PeerSupervisor> {
    PeerSupervisor::new(PeerId::new("peer-a").expect("peer id"))
}

fn runtime_state() -> Arc<RuntimeState> {
    let (event_tx, _event_rx) =
        tokio::sync::mpsc::unbounded_channel::<network_protocol::NetworkEvent>();
    Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ))
}

#[test]
fn peer_ids_are_validated_and_isolated() {
    assert!(PeerId::new("").is_err());
    assert!(PeerId::new("x".repeat(129).as_str()).is_err());
    let registry = PeerSupervisorRegistry::new();
    let first = registry.get_or_create("peer-a").expect("first supervisor");
    let second = registry.get_or_create("peer-b").expect("second supervisor");
    assert!(!Arc::ptr_eq(&first, &second));
    assert_eq!(registry.len(), 2);
}

#[test]
fn peer_id_traits_and_requirement_mapping_are_stable() {
    let peer = PeerId::try_from(String::from("peer-a")).expect("valid peer id");
    assert_eq!(peer.as_ref(), "peer-a");
    assert_eq!(peer.to_string(), "peer-a");
    assert!(PeerId::try_from("peer\n-a").is_err());

    for (class, expected) in [
        (
            CommunicationClass::ReliableMessage,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        ),
        (
            CommunicationClass::ReliableStream,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        ),
        (
            CommunicationClass::BulkTransfer,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        ),
        (
            CommunicationClass::UnreliableDatagram,
            crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM,
        ),
        (
            CommunicationClass::RealtimeMedia,
            crate::connect::DEFAULT_CONNECTION_CAPABILITY,
        ),
        (
            CommunicationClass::Unspecified,
            crate::connect::CAPABILITY_RELIABLE_MESSAGE,
        ),
    ] {
        let requirement = PeerRequirement::from_class(class);
        assert_eq!(requirement.capability_mask(), expected);
        assert_eq!(
            requirement.communication_class(),
            match class {
                CommunicationClass::ReliableStream | CommunicationClass::BulkTransfer => {
                    CommunicationClass::ReliableStream
                }
                CommunicationClass::UnreliableDatagram => CommunicationClass::UnreliableDatagram,
                CommunicationClass::RealtimeMedia => CommunicationClass::ReliableStream,
                CommunicationClass::Unspecified | CommunicationClass::ReliableMessage => {
                    CommunicationClass::ReliableMessage
                }
            }
        );
    }
    let combined = PeerRequirement::from_capability_mask(u8::MAX);
    assert_eq!(combined.capability_mask(), 0b111);
    assert!(combined.is_satisfied_by(combined));
    assert!(combined
        .extend(PeerRequirement::from_class(
            CommunicationClass::ReliableMessage
        ))
        .is_satisfied_by(combined));
}

#[test]
fn supervisor_rejects_invalid_duplicate_and_stopped_commands() {
    let supervisor = supervisor();
    assert!(matches!(
        supervisor.begin_connect("", CommunicationClass::ReliableMessage),
        Err(CoreNetworkError::InvalidCommandId)
    ));
    assert!(matches!(
        supervisor.begin_connect(&"x".repeat(129), CommunicationClass::ReliableMessage),
        Err(CoreNetworkError::InvalidCommandId)
    ));
    let first = supervisor
        .ensure("duplicate", CommunicationClass::ReliableMessage)
        .expect("first intent");
    assert!(matches!(
        supervisor.ensure("duplicate", CommunicationClass::ReliableMessage),
        Err(CoreNetworkError::DuplicateCommand)
    ));
    first.detach_completion();
    supervisor.stop();
    assert!(matches!(
        supervisor.ensure("after-stop", CommunicationClass::ReliableMessage),
        Err(CoreNetworkError::SupervisorStopping)
    ));
}

#[test]
fn online_message_path_queues_a_stronger_stream_generation() {
    let supervisor = supervisor();
    assert_eq!(
        supervisor
            .admit_inbound_with_capabilities(true, crate::connect::CAPABILITY_RELIABLE_MESSAGE,)
            .expect("admit message path"),
        PeerState::Online
    );
    let stream = supervisor
        .ensure("stream-upgrade", CommunicationClass::ReliableStream)
        .expect("stronger stream requirement");
    assert!(stream.is_new);
    assert_eq!(supervisor.state(), PeerState::Connecting);
    stream.detach_completion();
}

#[tokio::test]
async fn complete_ready_requeues_pending_stronger_waiters_when_retry_is_clear() {
    let supervisor = supervisor();
    let message = supervisor
        .ensure("message", CommunicationClass::ReliableMessage)
        .expect("message ensure");
    let stream = supervisor
        .ensure("stream", CommunicationClass::ReliableStream)
        .expect("stream ensure");
    let generation = message.generation;
    let mut mailbox = supervisor.take_mailbox().expect("mailbox");
    mailbox.try_recv().expect("initial attempt");
    {
        let mut inner = supervisor.inner.lock().expect("peer supervisor lock");
        inner.retry_scheduled = false;
    }
    assert_eq!(
        supervisor.complete_ready(
            generation,
            PeerRequirement::from_class(CommunicationClass::ReliableMessage),
            Ok(PeerState::Online),
        ),
        Ok(1)
    );
    assert_eq!(
        message.completion().await.expect("message completion"),
        Ok(PeerState::Online)
    );
    assert_eq!(
        mailbox
            .try_recv()
            .expect("retry intent")
            .required_capabilities,
        crate::connect::DEFAULT_CONNECTION_CAPABILITY | crate::connect::CAPABILITY_RELIABLE_STREAM
    );
    stream.detach_completion();
}

#[tokio::test]
async fn concurrent_connects_share_one_generation_and_completion() {
    let supervisor = supervisor();
    let first = supervisor
        .begin_connect("command-1", CommunicationClass::ReliableMessage)
        .expect("first intent");
    let second = supervisor
        .begin_connect("command-2", CommunicationClass::ReliableStream)
        .expect("joined intent");
    assert!(first.is_new);
    assert!(!second.is_new);
    assert_eq!(first.generation, second.generation);
    assert_eq!(supervisor.waiter_count(), 2);
    assert_eq!(
        supervisor
            .take_mailbox()
            .expect("mailbox")
            .recv()
            .await
            .unwrap()
            .generation,
        first.generation
    );
    assert_eq!(
        supervisor
            .complete(first.generation, Ok(PeerState::Online))
            .expect("complete"),
        2
    );
    assert_eq!(
        first.completion().await.expect("first waiter"),
        Ok(PeerState::Online)
    );
    assert_eq!(
        second.completion().await.expect("second waiter"),
        Ok(PeerState::Online)
    );
    assert_eq!(supervisor.state(), PeerState::Online);
}

#[tokio::test]
async fn incompatible_requirements_are_unioned_before_attempt() {
    let supervisor = supervisor();
    let stream = supervisor
        .ensure("stream", CommunicationClass::ReliableStream)
        .expect("stream ensure");
    let datagram = supervisor
        .ensure("datagram", CommunicationClass::UnreliableDatagram)
        .expect("datagram ensure");

    assert!(stream.is_new);
    assert!(!datagram.is_new);
    assert_eq!(stream.generation, datagram.generation);
    let expected = PeerRequirement::from_capability_mask(
        crate::connect::DEFAULT_CONNECTION_CAPABILITY
            | crate::connect::CAPABILITY_UNRELIABLE_DATAGRAM,
    );
    assert_eq!(supervisor.active_requirement(), Some(expected));

    stream.detach_completion();
    datagram.detach_completion();
}

#[test]
fn stronger_requirement_extends_active_generation() {
    let supervisor = supervisor();
    let message = supervisor
        .ensure("message", CommunicationClass::ReliableMessage)
        .expect("message ensure");
    let stream = supervisor
        .ensure("stream", CommunicationClass::ReliableStream)
        .expect("stream ensure");

    assert!(message.is_new);
    assert!(!stream.is_new);
    assert_eq!(message.generation, stream.generation);
    assert_eq!(
        supervisor.active_requirement(),
        Some(PeerRequirement::from_class(
            CommunicationClass::ReliableStream
        ))
    );
    message.detach_completion();
    stream.detach_completion();
}

#[tokio::test]
async fn weaker_ready_path_does_not_complete_stronger_waiter() {
    let supervisor = supervisor();
    let message = supervisor
        .ensure("message", CommunicationClass::ReliableMessage)
        .expect("message ensure");
    let stream = supervisor
        .ensure("stream", CommunicationClass::ReliableStream)
        .expect("stream ensure");

    assert_eq!(
        supervisor.complete_ready(
            message.generation,
            PeerRequirement::from_class(CommunicationClass::ReliableMessage),
            Ok(PeerState::Online),
        ),
        Ok(1)
    );
    assert_eq!(
        message.completion().await.expect("message completion"),
        Ok(PeerState::Online)
    );
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(20), stream.completion(),)
            .await
            .is_err()
    );
    assert_eq!(supervisor.waiter_count(), 1);
}

#[test]
fn business_ensure_does_not_enable_maintenance() {
    let supervisor = supervisor();
    let intent = supervisor
        .ensure("business", CommunicationClass::ReliableMessage)
        .expect("business ensure");

    assert!(!supervisor.maintain_connection());
    intent.detach_completion();
}

#[test]
fn connect_peer_enables_maintenance() {
    let supervisor = supervisor();
    let intent = supervisor
        .begin_connect("connect", CommunicationClass::ReliableMessage)
        .expect("explicit connect");

    assert!(supervisor.maintain_connection());
    intent.detach_completion();
}

#[tokio::test]
async fn concurrent_equivalent_requirements_share_attempt() {
    let supervisor = supervisor();
    let first = supervisor
        .ensure("first", CommunicationClass::ReliableMessage)
        .expect("first ensure");
    let second = supervisor
        .ensure("second", CommunicationClass::ReliableMessage)
        .expect("second ensure");
    let mut mailbox = supervisor.take_mailbox().expect("mailbox");

    assert!(first.is_new);
    assert!(!second.is_new);
    assert_eq!(first.generation, second.generation);
    assert_eq!(
        mailbox.recv().await.expect("one queued attempt").generation,
        first.generation
    );
    assert!(mailbox.try_recv().is_err());
    first.detach_completion();
    second.detach_completion();
}

#[tokio::test]
async fn path_loss_invalidates_generation_before_late_completion() {
    let supervisor = supervisor();
    let intent = supervisor
        .begin_connect("command-1", CommunicationClass::ReliableMessage)
        .expect("connect");
    let generation = intent.generation;

    supervisor.path_lost();

    assert_eq!(
        intent.completion().await.expect("completion"),
        Err(CoreNetworkError::Cancelled)
    );
    assert_eq!(supervisor.state(), PeerState::Offline);
    assert!(supervisor.maintain_connection());
    assert_eq!(
        supervisor.complete(generation, Ok(PeerState::Online)),
        Err(CoreNetworkError::StaleIntent)
    );
}

#[test]
fn business_ensure_does_not_enable_maintenance_but_connect_does() {
    let supervisor = supervisor();
    let business = supervisor
        .ensure("business-1", CommunicationClass::ReliableMessage)
        .expect("ensure");
    assert!(!supervisor.maintain_connection());
    supervisor.disconnect();
    business.detach_completion();

    let connect = supervisor
        .begin_connect("connect-1", CommunicationClass::ReliableMessage)
        .expect("connect");
    assert!(supervisor.maintain_connection());
    connect.detach_completion();
}

#[test]
fn passive_inbound_does_not_enable_maintenance_or_recovery() {
    let supervisor = supervisor();
    assert!(supervisor.admit_inbound(false).is_err());
    assert_eq!(
        supervisor.admit_inbound(true).expect("trusted inbound"),
        PeerState::Online
    );
    assert!(!supervisor.maintain_connection());
    supervisor.path_lost();
    assert_eq!(supervisor.state(), PeerState::Offline);
}

#[test]
fn stale_completion_cannot_change_a_new_generation() {
    let supervisor = supervisor();
    let first = supervisor
        .begin_connect("command-1", CommunicationClass::ReliableMessage)
        .expect("first intent");
    supervisor.disconnect();
    assert_eq!(
        supervisor.complete(first.generation, Ok(PeerState::Online)),
        Err(CoreNetworkError::StaleIntent)
    );
    assert_eq!(supervisor.state(), PeerState::Offline);
}

#[tokio::test]
async fn mailbox_and_resource_limits_are_bounded() {
    let closed_supervisor = supervisor();
    let receiver = closed_supervisor.take_mailbox().expect("mailbox");
    drop(receiver);
    assert!(matches!(
        closed_supervisor.begin_connect("command-1", CommunicationClass::ReliableMessage),
        Err(CoreNetworkError::SupervisorStopping)
    ));

    let supervisor = supervisor();
    let mut leases = Vec::new();
    for _ in 0..MAX_PEER_RESOURCES {
        leases.push(supervisor.acquire_resource().expect("resource lease"));
    }
    assert!(matches!(
        supervisor.acquire_resource(),
        Err(CoreNetworkError::ResourceLimit("peer resources"))
    ));
    drop(leases);
    assert!(supervisor.acquire_resource().is_ok());
}

#[test]
fn eviction_requires_offline_and_no_owned_work() {
    let registry = PeerSupervisorRegistry::new();
    registry.get_or_create("peer-a").expect("supervisor");
    assert!(registry.remove_if_evictable("peer-a").expect("evict"));

    let retained = registry.get_or_create("peer-b").expect("supervisor");
    let intent = retained
        .begin_connect("command-1", CommunicationClass::ReliableMessage)
        .expect("connect");
    assert!(!registry.remove_if_evictable("peer-b").expect("evict check"));
    retained.disconnect();
    intent.detach_completion();
    assert!(registry.remove_if_evictable("peer-b").expect("evict"));
}

#[tokio::test]
async fn mailbox_worker_starts_attempts_and_drains_repeated_intents() {
    let state = runtime_state();
    let registry = PeerSupervisorRegistry::new();
    for index in 0..(PEER_MAILBOX_CAPACITY * 2) {
        let command_id = format!("command-{index}");
        let intent = registry
            .start_connect(
                Arc::clone(&state),
                "peer-a",
                command_id,
                CommunicationClass::ReliableMessage,
            )
            .expect("mailbox consumer keeps up");
        assert!(intent.is_new);
        assert!(matches!(
            tokio::time::timeout(std::time::Duration::from_secs(1), intent.completion())
                .await
                .expect("attempt completion")
                .expect("completion waiter"),
            Err(CoreNetworkError::Cancelled)
        ));
        tokio::task::yield_now().await;
    }

    state.task_supervisor.shutdown().await;
}
