#[test]
fn command_result_ledger_claims_each_id_once() {
    let ledger = CommandResultLedger::new();
    assert_eq!(ledger.claim("command-1"), Ok(true));
    assert_eq!(ledger.claim("command-1"), Ok(false));
    ledger.complete("command-1");
    assert_eq!(ledger.claim("command-1"), Ok(false));
    assert_eq!(ledger.claim("command-2"), Ok(true));
}

#[test]
fn command_result_ledger_evicts_only_old_completed_ids() {
    let ledger = CommandResultLedger::new();
    for index in 0..=MAX_COMPLETED_COMMANDS {
        let command_id = format!("completed-{index}");
        assert_eq!(ledger.claim(&command_id), Ok(true));
        ledger.complete(&command_id);
    }

    assert_eq!(ledger.claim("completed-0"), Ok(true));
    assert_eq!(
        ledger.claim(&format!("completed-{MAX_COMPLETED_COMMANDS}")),
        Ok(false)
    );
}

#[tokio::test]
async fn command_worker_emits_a_terminal_error_for_duplicate_envelopes() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let (command_tx, command_rx) = tokio::sync::mpsc::channel(2);
    let worker = tokio::spawn(run_command_worker(command_rx, Arc::clone(&state)));

    for _ in 0..2 {
        command_tx
            .send(NetworkCommand {
                command_id: "duplicate-envelope".into(),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .await
            .expect("command worker is alive");
    }
    drop(command_tx);
    worker.await.expect("command worker joins");

    let mut results = Vec::new();
    while let Ok(event) = event_rx.try_recv() {
        if let Some(network_protocol::network_event::Payload::CommandResultV2(result)) =
            event.payload
        {
            results.push(result);
        }
    }
    assert_eq!(results.len(), 2);
    assert!(results
        .iter()
        .all(|result| result.command_id == "duplicate-envelope"));
    assert!(results.iter().any(|result| {
        result
            .error
            .as_ref()
            .is_some_and(|error| error.message.contains("already been completed"))
    }));
}

#[tokio::test]
async fn command_worker_continues_beyond_completed_history_capacity() {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel();
    let state = Arc::new(RuntimeState::new(
        event_tx,
        Arc::new(std::sync::atomic::AtomicU16::new(0)),
    ));
    let (command_tx, command_rx) = tokio::sync::mpsc::channel(8);
    let worker = tokio::spawn(run_command_worker(command_rx, Arc::clone(&state)));

    const COMMAND_COUNT: usize = 5000;
    for index in 0..COMMAND_COUNT {
        command_tx
            .send(NetworkCommand {
                command_id: format!("ledger-bound-{index}"),
                protocol_version: NETWORK_PROTOCOL_VERSION,
                payload: None,
            })
            .await
            .expect("command worker is alive");
    }
    drop(command_tx);
    worker.await.expect("command worker joins");

    let mut results = 0usize;
    while let Ok(event) = event_rx.try_recv() {
        let Some(network_protocol::network_event::Payload::CommandResultV2(result)) = event.payload
        else {
            continue;
        };
        results += 1;
        assert!(!result.error.as_ref().is_some_and(|error| {
            error.message.contains("command result ledger")
                || error.message.contains("pending command results")
        }));
    }
    assert_eq!(results, COMMAND_COUNT);
}
