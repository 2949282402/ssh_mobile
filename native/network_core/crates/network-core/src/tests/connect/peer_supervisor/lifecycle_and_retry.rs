
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
    assert_eq!(waiter_count(&supervisor), 1);
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

#[tokio::test]
async fn completion_failure_releases_waiters_and_marks_peer_offline() {
    let supervisor = supervisor();
    let intent = supervisor
        .ensure("failure", CommunicationClass::ReliableMessage)
        .expect("failure intent");
    let generation = intent.generation;
    let mut mailbox = supervisor.take_mailbox().expect("mailbox");
    mailbox.try_recv().expect("queued attempt");

    assert_eq!(
        supervisor.complete_ready(
            generation,
            PeerRequirement::from_class(CommunicationClass::ReliableMessage),
            Err(CoreNetworkError::NoRoute),
        ),
        Ok(1)
    );
    assert_eq!(
        intent.completion().await.expect("failure completion"),
        Err(CoreNetworkError::NoRoute)
    );
    assert_eq!(supervisor.state(), PeerState::Offline);
    assert!(supervisor.can_evict());
}

#[tokio::test]
async fn pending_retry_reports_supervisor_stop_when_mailbox_closes() {
    let supervisor = supervisor();
    let message = supervisor
        .ensure("message", CommunicationClass::ReliableMessage)
        .expect("message intent");
    let stream = supervisor
        .ensure("stream", CommunicationClass::ReliableStream)
        .expect("stream intent");
    let generation = message.generation;
    let mut mailbox = supervisor.take_mailbox().expect("mailbox");
    mailbox.try_recv().expect("queued attempt");
    drop(mailbox);
    supervisor
        .inner
        .lock()
        .expect("peer supervisor lock")
        .retry_scheduled = false;

    assert_eq!(
        supervisor.complete_ready(
            generation,
            PeerRequirement::from_class(CommunicationClass::ReliableMessage),
            Ok(PeerState::Online),
        ),
        Err(CoreNetworkError::SupervisorStopping)
    );
    assert_eq!(
        message.completion().await.expect("message completion"),
        Ok(PeerState::Online)
    );
    assert_eq!(
        stream.completion().await.expect("stream completion"),
        Err(CoreNetworkError::SupervisorStopping)
    );
    assert_eq!(supervisor.state(), PeerState::Offline);
}

#[tokio::test]
async fn worker_start_and_inbound_admission_fail_closed_after_runtime_stop() {
    let state = runtime_state();
    state.task_supervisor.cancel_root();
    let registry = PeerSupervisorRegistry::new();
    assert!(matches!(
        registry.start_connect(
            Arc::clone(&state),
            "peer-a",
            "connect".into(),
            CommunicationClass::ReliableMessage,
        ),
        Err(CoreNetworkError::SupervisorStopping)
    ));

    let supervisor = supervisor();
    supervisor.stop();
    assert_eq!(supervisor.disconnect(), 0);
    assert_eq!(
        supervisor.admit_inbound(true),
        Err(CoreNetworkError::SupervisorStopping)
    );
    assert!(matches!(
        supervisor.acquire_resource(),
        Err(CoreNetworkError::SupervisorStopping)
    ));
    state.task_supervisor.shutdown().await;
}
