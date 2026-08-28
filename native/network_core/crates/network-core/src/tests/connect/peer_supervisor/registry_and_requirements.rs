use super::*;

fn waiter_count(supervisor: &PeerSupervisor) -> usize {
    supervisor
        .inner
        .lock()
        .expect("peer supervisor lock")
        .waiters
        .len()
}

fn active_requirement(supervisor: &PeerSupervisor) -> Option<PeerRequirement> {
    supervisor
        .inner
        .lock()
        .expect("peer supervisor lock")
        .active_requirement
}

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
    let first_again = registry
        .get_or_create("peer-a")
        .expect("existing supervisor");
    assert!(Arc::ptr_eq(&first, &first_again));
}

#[test]
fn supervisor_registry_enforces_budgets_and_evicts_idle_entries() {
    let registry = PeerSupervisorRegistry::with_task_supervisor(
        crate::task_supervisor::RuntimeTaskSupervisor::new(),
    );
    assert!(registry.disconnect("missing").expect("missing disconnect") == 0);
    assert!(!registry
        .remove_if_evictable("missing")
        .expect("missing eviction"));
    assert!(registry.get_or_create("peer\n").is_err());

    for index in 0..crate::connect::MAX_CONFIGURED_PEERS {
        registry
            .get_or_create_with_configured(&format!("idle-{index}"), false)
            .expect("idle supervisor");
    }
    registry
        .get_or_create("evicted-peer")
        .expect("an idle supervisor is evictable");
    let remaining_idle = (0..crate::connect::MAX_CONFIGURED_PEERS)
        .filter(|index| {
            registry
                .remove_if_evictable(&format!("idle-{index}"))
                .expect("idle supervisor eviction")
        })
        .count();
    assert_eq!(
        remaining_idle,
        crate::connect::MAX_CONFIGURED_PEERS - 1,
        "admitting one peer evicts exactly one idle supervisor"
    );
    assert!(registry
        .remove_if_evictable("evicted-peer")
        .expect("evicted supervisor remains addressable"));

    let configured = PeerSupervisorRegistry::new();
    for index in 0..crate::connect::MAX_CONFIGURED_PEERS {
        configured
            .get_or_create_with_configured(&format!("configured-{index}"), true)
            .expect("configured supervisor");
    }
    assert!(matches!(
        configured.get_or_create_with_configured("configured-overflow", true),
        Err(CoreNetworkError::ResourceLimit("configured peers"))
    ));

    let active = PeerSupervisorRegistry::new();
    let state = runtime_state();
    for index in 0..crate::connect::MAX_ACTIVE_PEERS {
        let peer = active
            .get_or_create(&format!("active-{index}"))
            .expect("active supervisor");
        peer.begin_connect(
            &format!("active-command-{index}"),
            CommunicationClass::ReliableMessage,
        )
        .expect("active intent")
        .detach_completion();
    }
    assert!(matches!(
        active.start_connect(
            state,
            "active-overflow",
            "active-overflow-command".into(),
            CommunicationClass::ReliableMessage,
        ),
        Err(CoreNetworkError::ResourceLimit("active peers"))
    ));
}

#[test]
fn supervisor_accessors_and_child_budget_are_consistent() {
    let supervisor = supervisor();
    assert_eq!(supervisor.peer_id().as_str(), "peer-a");
    let generation = supervisor.generation();
    assert_eq!(generation.get(), 0);
    assert!(supervisor.is_current(generation));
    assert!(supervisor.take_mailbox().is_some());
    assert!(supervisor.take_mailbox().is_none());

    assert!(supervisor.mark_child_started().is_ok());
    assert!(matches!(
        supervisor.mark_child_started(),
        Err(CoreNetworkError::ResourceLimit("peer establishment"))
    ));
    supervisor.mark_child_finished();
    assert!(supervisor.can_evict());

    supervisor.set_configured(true);
    assert!(supervisor.can_evict());
    supervisor.stop();
    assert!(!supervisor.is_current(generation));
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
    assert_eq!(waiter_count(&supervisor), 2);
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
    assert_eq!(active_requirement(&supervisor), Some(expected));

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
        active_requirement(&supervisor),
        Some(PeerRequirement::from_class(
            CommunicationClass::ReliableStream
        ))
    );
    message.detach_completion();
    stream.detach_completion();
}
