/// Receiver admission is fail-closed: an authenticated sender must already be
/// present in the receiver's native peer registry.
#[test]
fn receiver_missing_peer_registration_rejects_inbound_connection() {
    let runtime_a = NetworkRuntime::new().expect("runtime A");
    let runtime_b = NetworkRuntime::new().expect("runtime B");
    runtime_a.start().expect("start runtime A");
    runtime_b.start().expect("start runtime B");
    let identity_seed_a = [13u8; 32];
    let identity_seed_b = [23u8; 32];
    let public_key_b =
        DeviceIdentity::from_private_keys("missing-b".into(), identity_seed_b, [33u8; 32])
            .public_identity_key()
            .to_bytes();
    let test_root =
        std::env::temp_dir().join(format!("ssh-mobile-missing-peer-{}", rand::random::<u64>()));
    let _address_a = configure_runtime_for_test(
        &runtime_a,
        "missing-a",
        identity_seed_a,
        [34u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-a"),
    );
    let address_b = configure_runtime_for_test(
        &runtime_b,
        "missing-b",
        identity_seed_b,
        [33u8; 32],
        SocketAddr::from(([127, 0, 0, 1], 0)),
        test_root.join("receive-b"),
    );
    send_and_expect_accepted(
        &runtime_a,
        upsert_command("peer-b", "missing-b", address_b, public_key_b, [33u8; 32]),
    );
    // Deliberately do not register missing-a in runtime_b.
    let command_id = "connect-missing-receiver";
    runtime_a
        .send_command(NetworkCommand {
            command_id: command_id.into(),
            protocol_version: NETWORK_PROTOCOL_VERSION,
            payload: Some(network_command::Payload::ConnectPeer(ConnectPeerCommand {
                peer_id: "missing-b".into(),
                intent: 0,
                communication_class: 0,
            })),
        })
        .expect("queue connect command");

    let result = poll_until(&runtime_a, Duration::from_secs(15), |event| {
        matches!(
            &event.payload,
            Some(network_event::Payload::CommandResultV2(result))
                if result.command_id == command_id
        )
    })
    .expect("connect command result");
    let Some(network_event::Payload::CommandResultV2(result)) = result.payload else {
        panic!("expected command result");
    };
    assert_eq!(result.state, CommandResultState::Failed as i32);
    assert!(
        poll_until(&runtime_b, Duration::from_millis(500), |event| {
            matches!(
                &event.payload,
                Some(network_event::Payload::PeerState(state))
                    if state.peer_id == "missing-a"
                        && state.state == PeerConnectionState::Connected as i32
            )
        })
        .is_none(),
        "unregistered sender must not be admitted"
    );

    runtime_a.stop().expect("stop runtime A");
    runtime_b.stop().expect("stop runtime B");
    fs::remove_dir_all(test_root).ok();
}

