/// 构造一个没有配置直连 endpoint 的 PeerConfig（测试 resolve 权威失败路径用）。
fn peer_without_endpoint() -> crate::runtime::PeerConfig {
    crate::runtime::PeerConfig {
        endpoint: None,
        identity_public_key: [0u8; 32],
        e2e_public_key: [0u8; 32],
        e2ee_policy: network_protocol::E2eePolicy::Required,
    }
}

/// Test-local gate that keeps a real coordinator inside Stage B after its
/// Resolve/Offer evidence has been recorded.  It makes the reconnect tests
/// deterministic without adding a production injection point.
struct StubOfferGate {
    started: tokio::sync::Notify,
    release: tokio::sync::Notify,
    hold: std::sync::atomic::AtomicBool,
    started_flag: std::sync::atomic::AtomicBool,
}

impl StubOfferGate {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            started: tokio::sync::Notify::new(),
            release: tokio::sync::Notify::new(),
            hold: std::sync::atomic::AtomicBool::new(false),
            started_flag: std::sync::atomic::AtomicBool::new(false),
        })
    }

    fn hold(&self) {
        self.hold.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    async fn wait_started(&self) {
        loop {
            if self.started_flag.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            let notified = self.started.notified();
            if self.started_flag.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }

    fn release(&self) {
        self.hold.store(false, std::sync::atomic::Ordering::SeqCst);
        self.release.notify_one();
    }

    async fn wait_if_held(&self) {
        if self.hold.load(std::sync::atomic::Ordering::SeqCst) {
            self.started_flag
                .store(true, std::sync::atomic::Ordering::SeqCst);
            self.started.notify_one();
            self.release.notified().await;
        }
    }
}

/// 预置 Resolve 状态的 mock 控制面（测试用）。
struct StubControl {
    status: network_relay::v2::ResolveStatus,
    discovery: Option<DiscoverySnapshot>,
    resolve_calls: std::sync::atomic::AtomicUsize,
    connectivity_calls: std::sync::atomic::AtomicUsize,
    reserve_calls: std::sync::atomic::AtomicUsize,
    resolve_error: bool,
    resolve_never: bool,
    not_ready_once: std::sync::atomic::AtomicBool,
    usable: std::sync::atomic::AtomicBool,
    connectivity_answer: std::sync::Mutex<Option<network_relay::v2::ConnectivityAnswer>>,
    relay_reservation: std::sync::Mutex<Option<network_relay::v2::RelayReserveResponse>>,
    reserve_at: std::sync::Mutex<Option<Instant>>,
    calls: std::sync::Mutex<Vec<&'static str>>,
    call_times: std::sync::Mutex<Vec<(&'static str, Instant)>>,
    attempt_id_target: std::sync::Mutex<Option<Arc<std::sync::Mutex<Option<String>>>>>,
    ownership_state: std::sync::Mutex<Option<Arc<RuntimeState>>>,
    first_resolve_saw_owned_session: Arc<std::sync::atomic::AtomicBool>,
    offer_gate: Arc<StubOfferGate>,
}

impl StubControl {
    fn new(
        status: network_relay::v2::ResolveStatus,
        discovery: Option<DiscoverySnapshot>,
    ) -> Arc<Self> {
        Arc::new(Self {
            status,
            discovery,
            resolve_calls: std::sync::atomic::AtomicUsize::new(0),
            connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
            reserve_calls: std::sync::atomic::AtomicUsize::new(0),
            resolve_error: false,
            resolve_never: false,
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
        })
    }

    fn error() -> Arc<Self> {
        Arc::new(Self {
            status: ResolveStatus::Unknown,
            discovery: None,
            resolve_calls: std::sync::atomic::AtomicUsize::new(0),
            connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
            reserve_calls: std::sync::atomic::AtomicUsize::new(0),
            resolve_error: true,
            resolve_never: false,
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
        })
    }

    fn timeout() -> Arc<Self> {
        Arc::new(Self {
            status: ResolveStatus::Unknown,
            discovery: None,
            resolve_calls: std::sync::atomic::AtomicUsize::new(0),
            connectivity_calls: std::sync::atomic::AtomicUsize::new(0),
            reserve_calls: std::sync::atomic::AtomicUsize::new(0),
            resolve_error: false,
            resolve_never: true,
            not_ready_once: std::sync::atomic::AtomicBool::new(false),
            usable: std::sync::atomic::AtomicBool::new(true),
            connectivity_answer: std::sync::Mutex::new(None),
            relay_reservation: std::sync::Mutex::new(None),
            reserve_at: std::sync::Mutex::new(None),
            calls: std::sync::Mutex::new(Vec::new()),
            call_times: std::sync::Mutex::new(Vec::new()),
            attempt_id_target: std::sync::Mutex::new(None),
            ownership_state: std::sync::Mutex::new(None),
            first_resolve_saw_owned_session: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            offer_gate: StubOfferGate::new(),
        })
    }

    fn observe_session_ownership(&self, state: Arc<RuntimeState>) {
        *self
            .ownership_state
            .lock()
            .expect("stub ownership state lock") = Some(state);
    }

    fn observe_attempt_id(&self, target: Arc<std::sync::Mutex<Option<String>>>) {
        *self
            .attempt_id_target
            .lock()
            .expect("stub attempt id target lock") = Some(target);
    }

    fn return_not_ready_once(&self) {
        self.not_ready_once
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    fn set_usable(&self, usable: bool) {
        self.usable
            .store(usable, std::sync::atomic::Ordering::SeqCst);
    }

    fn set_connectivity_answer(&self, answer: network_relay::v2::ConnectivityAnswer) {
        *self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock") = Some(answer);
    }

    fn set_relay_reservation(&self, reservation: network_relay::v2::RelayReserveResponse) {
        *self
            .relay_reservation
            .lock()
            .expect("stub relay reservation lock") = Some(reservation);
    }

    fn hold_offer(&self) {
        self.offer_gate.hold();
    }

    async fn wait_offer_started(&self) {
        self.offer_gate.wait_started().await;
    }

    fn release_offer(&self) {
        self.offer_gate.release();
    }

    fn first_resolve_saw_owned_session(&self) -> bool {
        self.first_resolve_saw_owned_session
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    fn resolve_calls(&self) -> usize {
        self.resolve_calls.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn connectivity_calls(&self) -> usize {
        self.connectivity_calls
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    fn reserve_calls(&self) -> usize {
        self.reserve_calls.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn reserve_at(&self) -> Option<Instant> {
        *self.reserve_at.lock().expect("reserve timestamp lock")
    }

    fn call_times(&self) -> Vec<(&'static str, Instant)> {
        self.call_times
            .lock()
            .expect("stub call timestamp lock")
            .clone()
    }

    fn record_call(&self, name: &'static str) {
        self.calls.lock().expect("stub call log lock").push(name);
        self.call_times
            .lock()
            .expect("stub call timestamp lock")
            .push((name, Instant::now()));
    }

    fn call_order(&self) -> Vec<&'static str> {
        self.calls.lock().expect("stub call log lock").clone()
    }
}

impl crate::discovery::DiscoveryControlPlane for StubControl {
    fn publish_discovery(
        &self,
        _request_id: u64,
        _snapshot: DiscoverySnapshot,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Result<network_relay::v2::DiscoveryAck, RelayError>>
                + Send
                + '_,
        >,
    > {
        Box::pin(async { Err(RelayError::NotConnected) })
    }

    fn resolve_peer(
        &self,
        _target_device_id: &str,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = Result<network_relay::v2::ResolvePeerResponse, RelayError>,
                > + Send
                + '_,
        >,
    > {
        self.record_call("resolve");
        self.resolve_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let first_resolve = self.resolve_calls() == 1;
        let status = self.status;
        let not_ready_once = self
            .not_ready_once
            .load(std::sync::atomic::Ordering::SeqCst)
            && first_resolve;
        let status = if not_ready_once {
            ResolveStatus::NotReady
        } else {
            status
        };
        let discovery = if not_ready_once {
            None
        } else {
            self.discovery.clone()
        };
        let resolve_error = self.resolve_error;
        let resolve_never = self.resolve_never;
        let ownership_state = self
            .ownership_state
            .lock()
            .expect("stub ownership state lock")
            .clone();
        let first_resolve_saw_owned_session = Arc::clone(&self.first_resolve_saw_owned_session);
        Box::pin(async move {
            if first_resolve {
                if let Some(state) = ownership_state {
                    if state
                        .connection_sessions
                        .current_session_id("peer-b")
                        .await
                        .is_some()
                    {
                        first_resolve_saw_owned_session
                            .store(true, std::sync::atomic::Ordering::SeqCst);
                    }
                }
            }
            if resolve_error {
                return Err(RelayError::NotConnected);
            }
            if resolve_never {
                return std::future::pending::<
                    Result<network_relay::v2::ResolvePeerResponse, RelayError>,
                >()
                .await;
            }
            Ok(network_relay::v2::ResolvePeerResponse {
                request_id: 1,
                status: status as i32,
                discovery,
                retry_after_ms: 500,
            })
        })
    }

    fn is_usable(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send + '_>> {
        let usable = self.usable.load(std::sync::atomic::Ordering::SeqCst);
        Box::pin(async move { usable })
    }

    fn begin_connectivity_attempt(
        &self,
        attempt_id: String,
        target_device_id: String,
        _initiator_device_id: String,
        _initiator_runtime_epoch: RuntimeEpoch,
        _initiator_revision: u32,
        _initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = Result<network_relay::v2::ConnectivityAttemptStart, RelayError>,
                > + Send
                + '_,
        >,
    > {
        if let Some(target) = self
            .attempt_id_target
            .lock()
            .expect("stub attempt id target lock")
            .clone()
        {
            *target.lock().expect("Stage C attempt id lock") = Some(attempt_id.clone());
        }
        let mut answer = self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock")
            .clone();
        if let Some(answer) = answer.as_mut() {
            // The production control client binds the answer waiter to the
            // freshly generated attempt id.  Keep the fixture convenient for
            // success-path tests while still allowing an explicit id to test
            // stale-answer rejection.
            if answer.attempt_id.is_empty() {
                answer.attempt_id = attempt_id;
            }
        }
        let offer_gate = Arc::clone(&self.offer_gate);
        Box::pin(async move {
            let resolved = self.resolve_peer(&target_device_id).await?;
            let status = resolved.status;
            let retry_after_ms = resolved.retry_after_ms;
            if resolved.status != ResolveStatus::Ready as i32 {
                return Ok(network_relay::v2::ConnectivityAttemptStart::new(
                    resolved,
                    async move {
                        Err(RelayError::Protocol(format!(
                                "connectivity attempt not started: resolve status={status} retry_after_ms={retry_after_ms}"
                            )))
                    },
                ));
            }
            self.record_call("offer");
            self.connectivity_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            offer_gate.wait_if_held().await;
            Ok(network_relay::v2::ConnectivityAttemptStart::new(
                resolved,
                async move { answer.ok_or(RelayError::NotConnected) },
            ))
        })
    }

    fn start_connectivity_attempt(
        &self,
        _attempt_id: String,
        _target_device_id: String,
        _initiator_device_id: String,
        _initiator_runtime_epoch: RuntimeEpoch,
        _initiator_revision: u32,
        _initiator_snapshot: Option<DiscoverySnapshot>,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = Result<network_relay::v2::ConnectivityAnswer, RelayError>,
                > + Send
                + '_,
        >,
    > {
        self.record_call("offer");
        self.connectivity_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let answer = self
            .connectivity_answer
            .lock()
            .expect("stub connectivity answer lock")
            .clone();
        Box::pin(async move { answer.ok_or(RelayError::NotConnected) })
    }

    fn reserve_relay(
        &self,
        _attempt_id: String,
        _target_device_id: String,
        _desired_lifetime_s: u32,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<
                    Output = Result<network_relay::v2::RelayReserveResponse, RelayError>,
                > + Send
                + '_,
        >,
    > {
        *self.reserve_at.lock().expect("reserve timestamp lock") = Some(Instant::now());
        self.record_call("reserve");
        self.reserve_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let reservation = self
            .relay_reservation
            .lock()
            .expect("stub relay reservation lock")
            .clone();
        let reserve_never = self.resolve_never;
        Box::pin(async move {
            if reserve_never {
                return std::future::pending::<
                    Result<network_relay::v2::RelayReserveResponse, RelayError>,
                >()
                .await;
            }
            reservation.ok_or(RelayError::NotConnected)
        })
    }
}

