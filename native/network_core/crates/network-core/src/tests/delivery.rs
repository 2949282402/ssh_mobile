use super::*;

fn retry_policy() -> RetryPolicy {
    RetryPolicy {
        max_attempts: 3,
        initial_backoff: Duration::from_secs(1),
        max_backoff: Duration::from_secs(4),
        ttl: Some(Duration::from_secs(30)),
        max_total_retry_bytes: Some(32),
    }
}

fn config() -> DeliveryConfig {
    DeliveryConfig {
        max_pending_messages: 4,
        max_pending_bytes: 32,
        max_payload_bytes: 16,
        dedup_max_entries: 4,
        dedup_ttl: Duration::from_secs(10),
        application_ack_timeout: Duration::from_secs(5 * 60),
        max_reorder_messages: 2,
        max_reorder_bytes: 8,
        max_sequence_gap: 4,
    }
}

const SHORT_ACK_TIMEOUT: Duration = Duration::from_millis(50);

fn short_timeout_config() -> DeliveryConfig {
    DeliveryConfig {
        application_ack_timeout: SHORT_ACK_TIMEOUT,
        ..config()
    }
}

fn ordered_message(sequence: u64, message_id: u8) -> OrderedMessage {
    OrderedMessage {
        peer_id: "peer-a".into(),
        // wire 信封的 SessionId：单测中仅随 OrderedMessage 传递，不做 key。
        session_id: "session-a".into(),
        channel_id: "control".into(),
        message_id: MessageId([message_id; MESSAGE_ID_BYTES]),
        sequence,
        policy: DeliveryPolicy::SessionBoundOrdered,
        payload: vec![message_id],
    }
}

#[test]
fn ordered_channel_releases_only_the_next_contiguous_message() {
    let mut state = OrderedChannelState::default();
    assert_eq!(
        state.insert(ordered_message(2, 2), 4, 16, 4),
        OrderedInsertResult::Buffered
    );
    assert_eq!(
        state.insert(ordered_message(1, 1), 4, 16, 4),
        OrderedInsertResult::Buffered
    );
    assert_eq!(
        state.insert(ordered_message(0, 0), 4, 16, 4),
        OrderedInsertResult::Ready
    );
    assert_eq!(
        state
            .acknowledge(MessageId([0; MESSAGE_ID_BYTES]))
            .map(|message| message.sequence),
        Some(1)
    );
    assert_eq!(
        state
            .acknowledge(MessageId([1; MESSAGE_ID_BYTES]))
            .map(|message| message.sequence),
        Some(2)
    );
    assert_eq!(state.acknowledge(MessageId([2; MESSAGE_ID_BYTES])), None);
}

#[test]
fn ordered_channel_rejects_sequence_gap_and_reorder_overflow() {
    let mut state = OrderedChannelState::default();
    assert_eq!(
        state.insert(ordered_message(5, 5), 4, 16, 4),
        OrderedInsertResult::Rejected
    );
    assert_eq!(
        state.insert(ordered_message(2, 2), 1, 16, 4),
        OrderedInsertResult::Buffered
    );
    assert_eq!(
        state.insert(ordered_message(3, 3), 1, 16, 4),
        OrderedInsertResult::Rejected
    );
    assert_eq!(
        state.insert(
            OrderedMessage {
                payload: vec![0; 17],
                ..ordered_message(1, 1)
            },
            4,
            16,
            4,
        ),
        OrderedInsertResult::Rejected
    );
}

#[tokio::test]
async fn zero_dedup_window_releases_the_message_after_ack() {
    let manager = DeliveryManager::with_config(DeliveryConfig {
        dedup_max_entries: 0,
        ..config()
    });
    let message_id = MessageId([210; MESSAGE_ID_BYTES]);
    let now = Instant::now();

    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::New
    );
    assert!(manager
        .complete_incoming("peer-a", "control", message_id)
        .await
        .is_some());
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::New,
        "a zero-sized processed history must not retain ACKed duplicates"
    );
}

#[test]
fn terminal_history_stays_bounded_at_the_configured_limit() {
    let mut store = DeliveryStore::new();
    let message_id = MessageId([211; MESSAGE_ID_BYTES]);
    for index in 0..MAX_TERMINAL_OUTCOMES {
        record_terminal(
            &mut store,
            DeliveryIdentity::new(format!("peer-{index}"), message_id).expect("peer identity"),
            DeliveryTerminalOutcome::Acknowledged,
        );
    }

    let newest = DeliveryIdentity::new("peer-new", message_id).expect("new identity");
    record_terminal(
        &mut store,
        newest.clone(),
        DeliveryTerminalOutcome::Cancelled,
    );

    assert_eq!(store.terminal_outcomes.len(), MAX_TERMINAL_OUTCOMES);
    assert_eq!(
        store.terminal_outcomes.get(&newest),
        Some(&DeliveryTerminalOutcome::Cancelled)
    );
}

#[tokio::test]
async fn ordered_delivery_waits_for_application_ack_before_releasing_buffer() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    for (sequence, id) in [(0, 0), (2, 2), (1, 1)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        let result = manager.accept_ordered(message).await;
        if sequence == 0 {
            assert_eq!(result, OrderedInsertResult::Ready);
        } else {
            assert_eq!(result, OrderedInsertResult::Buffered);
        }
    }

    let first = manager
        .complete_incoming("peer-a", "control", MessageId([0; MESSAGE_ID_BYTES]))
        .await
        .expect("first ordered message should be ACKable");
    assert_eq!(
        first.next_ordered.as_ref().map(|message| message.sequence),
        Some(1)
    );
    let second = manager
        .complete_incoming("peer-a", "control", MessageId([1; MESSAGE_ID_BYTES]))
        .await
        .expect("second ordered message should be ACKable after release");
    assert_eq!(
        second.next_ordered.as_ref().map(|message| message.sequence),
        Some(2)
    );
}

#[tokio::test]
async fn ordered_buffered_message_does_not_keep_an_ack_deadline() {
    let manager = DeliveryManager::with_config(short_timeout_config());
    let now = Instant::now();
    for (sequence, id) in [(0, 60), (1, 61)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered_at(message, now).await,
            if sequence == 0 {
                OrderedInsertResult::Ready
            } else {
                OrderedInsertResult::Buffered
            }
        );
    }
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([61; MESSAGE_ID_BYTES]))
            .await,
        Some((ActiveIncomingState::OrderedBuffered, None))
    );

    let head_ack_at = now + Duration::from_millis(25);
    let completion = manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([60; MESSAGE_ID_BYTES]),
            head_ack_at,
        )
        .await
        .expect("head message should be ACKable");
    assert_eq!(
        completion
            .next_ordered
            .as_ref()
            .map(|message| message.sequence),
        Some(1)
    );
    let promoted_deadline = head_ack_at + SHORT_ACK_TIMEOUT;
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([61; MESSAGE_ID_BYTES]))
            .await,
        Some((ActiveIncomingState::InFlight, Some(promoted_deadline)))
    );

    let old_deadline = now + SHORT_ACK_TIMEOUT;
    assert!(manager
        .expire_incoming("peer-a", old_deadline + Duration::from_millis(1))
        .await
        .is_empty());
    assert!(manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([61; MESSAGE_ID_BYTES]),
            old_deadline + Duration::from_millis(1),
        )
        .await
        .is_some());
}

#[tokio::test]
async fn ordered_buffer_promotion_gets_a_full_ack_timeout_window() {
    let manager = DeliveryManager::with_config(short_timeout_config());
    let now = Instant::now();
    for (sequence, id) in [(0, 62), (1, 63)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered_at(message, now).await,
            if sequence == 0 {
                OrderedInsertResult::Ready
            } else {
                OrderedInsertResult::Buffered
            }
        );
    }

    let head_ack_at = now + Duration::from_millis(49);
    let completion = manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([62; MESSAGE_ID_BYTES]),
            head_ack_at,
        )
        .await
        .expect("head message should be ACKable");
    assert_eq!(
        completion
            .next_ordered
            .as_ref()
            .map(|message| message.sequence),
        Some(1)
    );
    let promoted_deadline = head_ack_at + SHORT_ACK_TIMEOUT;
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([63; MESSAGE_ID_BYTES]))
            .await,
        Some((ActiveIncomingState::InFlight, Some(promoted_deadline)))
    );

    assert!(manager
        .expire_incoming("peer-a", promoted_deadline - Duration::from_millis(1),)
        .await
        .is_empty());
    let expired = manager
        .expire_incoming("peer-a", promoted_deadline + Duration::from_millis(1))
        .await;
    assert_eq!(expired.len(), 1);
    assert!(expired[0].ordered_channel_failed);
    assert_eq!(manager.incoming_state_counts().await, (0, 1, 0));
}

#[tokio::test]
async fn ordered_buffered_messages_restart_ack_timeout_in_sequence() {
    let manager = DeliveryManager::with_config(short_timeout_config());
    let now = Instant::now();
    for (sequence, id) in [(0, 64), (1, 65), (2, 66)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered_at(message, now).await,
            if sequence == 0 {
                OrderedInsertResult::Ready
            } else {
                OrderedInsertResult::Buffered
            }
        );
    }
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([65; MESSAGE_ID_BYTES]))
            .await,
        Some((ActiveIncomingState::OrderedBuffered, None))
    );
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([66; MESSAGE_ID_BYTES]))
            .await,
        Some((ActiveIncomingState::OrderedBuffered, None))
    );

    let first_ack_at = now + Duration::from_millis(25);
    let first_completion = manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([64; MESSAGE_ID_BYTES]),
            first_ack_at,
        )
        .await
        .expect("first message should be ACKable");
    assert_eq!(
        first_completion
            .next_ordered
            .as_ref()
            .map(|message| message.sequence),
        Some(1)
    );
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([65; MESSAGE_ID_BYTES]))
            .await,
        Some((
            ActiveIncomingState::InFlight,
            Some(first_ack_at + SHORT_ACK_TIMEOUT),
        ))
    );
    assert!(manager
        .expire_incoming("peer-a", now + Duration::from_millis(51))
        .await
        .is_empty());

    let second_ack_at = now + Duration::from_millis(60);
    let second_completion = manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([65; MESSAGE_ID_BYTES]),
            second_ack_at,
        )
        .await
        .expect("second message should be ACKable after release");
    assert_eq!(
        second_completion
            .next_ordered
            .as_ref()
            .map(|message| message.sequence),
        Some(2)
    );
    assert_eq!(
        manager
            .incoming_record_state("peer-a", "control", MessageId([66; MESSAGE_ID_BYTES]))
            .await,
        Some((
            ActiveIncomingState::InFlight,
            Some(second_ack_at + SHORT_ACK_TIMEOUT),
        ))
    );
    assert!(manager
        .expire_incoming("peer-a", now + Duration::from_millis(101))
        .await
        .is_empty());

    let final_completion = manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([66; MESSAGE_ID_BYTES]),
            now + Duration::from_millis(105),
        )
        .await
        .expect("third message should be ACKable after release");
    assert!(final_completion.next_ordered.is_none());
    assert_eq!(manager.incoming_state_counts().await, (0, 3, 0));
}

#[tokio::test]
async fn inflight_survives_processed_dedup_ttl_until_application_ack() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message_id = MessageId([20; MESSAGE_ID_BYTES]);
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::New
    );

    // 11 seconds exceeds this test's processed-history TTL, but remains
    // below the independent application ACK timeout.
    for id in [21, 22] {
        assert_eq!(
            manager
                .begin_incoming(
                    "peer-a",
                    "control",
                    MessageId([id; MESSAGE_ID_BYTES]),
                    1,
                    now + Duration::from_secs(11),
                )
                .await,
            DedupDecision::New
        );
    }
    assert_eq!(manager.incoming_state_counts().await.0, 3);
    assert!(manager
        .complete_incoming("peer-a", "control", message_id)
        .await
        .is_some());
}

#[tokio::test]
async fn ordered_buffer_survives_processed_dedup_ttl_and_releases_in_sequence() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    for (sequence, id) in [(2, 2), (1, 1)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(message).await,
            OrderedInsertResult::Buffered
        );
    }

    let first = ordered_message(0, 0);
    assert_eq!(
        manager
            .begin_incoming(
                &first.peer_id,
                &first.channel_id,
                first.message_id,
                1,
                now + Duration::from_secs(11),
            )
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager.accept_ordered(first).await,
        OrderedInsertResult::Ready
    );

    let mut released = Vec::new();
    for id in [0, 1, 2] {
        let completion = manager
            .complete_incoming_at(
                "peer-a",
                "control",
                MessageId([id; MESSAGE_ID_BYTES]),
                now + Duration::from_secs(11),
            )
            .await
            .expect("ordered message should be ACKable");
        released.push(id);
        if id < 2 {
            assert_eq!(
                completion
                    .next_ordered
                    .as_ref()
                    .map(|message| message.sequence),
                Some(u64::from(id + 1))
            );
        } else {
            assert!(completion.next_ordered.is_none());
        }
    }
    assert_eq!(released, vec![0, 1, 2]);
    assert_eq!(manager.incoming_state_counts().await, (0, 3, 0));
}

#[tokio::test]
async fn processed_history_pressure_never_evicts_active_or_ordered_buffered() {
    let mut limited = config();
    limited.dedup_max_entries = 2;
    let manager = DeliveryManager::with_config(limited);
    let now = Instant::now();

    let first = ordered_message(0, 0);
    assert_eq!(
        manager
            .begin_incoming(&first.peer_id, &first.channel_id, first.message_id, 1, now,)
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager.accept_ordered(first).await,
        OrderedInsertResult::Ready
    );
    let buffered = ordered_message(1, 1);
    assert_eq!(
        manager
            .begin_incoming(
                &buffered.peer_id,
                &buffered.channel_id,
                buffered.message_id,
                1,
                now,
            )
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager.accept_ordered(buffered).await,
        OrderedInsertResult::Buffered
    );

    for (offset, id) in [10u8, 11, 12].into_iter().enumerate() {
        let at = now + Duration::from_secs((offset + 1) as u64);
        let message_id = MessageId([id; MESSAGE_ID_BYTES]);
        assert_eq!(
            manager
                .begin_incoming("peer-a", "history", message_id, 1, at)
                .await,
            DedupDecision::New
        );
        assert!(manager
            .complete_incoming_at("peer-a", "history", message_id, at)
            .await
            .is_some());
    }
    assert_eq!(manager.incoming_state_counts().await, (2, 2, 1));

    assert!(manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([0; MESSAGE_ID_BYTES]),
            now + Duration::from_secs(5),
        )
        .await
        .is_some());
    assert!(manager
        .complete_incoming_at(
            "peer-a",
            "control",
            MessageId([1; MESSAGE_ID_BYTES]),
            now + Duration::from_secs(5),
        )
        .await
        .is_some());
}

#[tokio::test]
async fn processed_history_is_the_only_state_evicted_by_capacity() {
    let mut limited = config();
    limited.dedup_max_entries = 2;
    let manager = DeliveryManager::with_config(limited);
    let now = Instant::now();
    for (offset, id) in [30u8, 31, 32].into_iter().enumerate() {
        let at = now + Duration::from_secs(offset as u64);
        let message_id = MessageId([id; MESSAGE_ID_BYTES]);
        assert_eq!(
            manager
                .begin_incoming("peer-a", "control", message_id, 1, at)
                .await,
            DedupDecision::New
        );
        assert!(manager
            .complete_incoming_at("peer-a", "control", message_id, at)
            .await
            .is_some());
    }
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([30; MESSAGE_ID_BYTES]),
                1,
                now + Duration::from_secs(4),
            )
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([31; MESSAGE_ID_BYTES]),
                1,
                now + Duration::from_secs(4),
            )
            .await,
        DedupDecision::DuplicateProcessed
    );
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([32; MESSAGE_ID_BYTES]),
                1,
                now + Duration::from_secs(4),
            )
            .await,
        DedupDecision::DuplicateProcessed
    );
}

#[tokio::test]
async fn application_ack_timeout_fails_ordered_channel_without_skipping_sequence() {
    let manager = DeliveryManager::with_config(short_timeout_config());
    let now = Instant::now();
    let timeout_at = now + SHORT_ACK_TIMEOUT + Duration::from_millis(1);
    for (sequence, id) in [(0, 40), (1, 41)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert!(matches!(
            manager.accept_ordered_at(message, now).await,
            OrderedInsertResult::Ready | OrderedInsertResult::Buffered
        ));
    }
    let expired = manager.expire_incoming("peer-a", timeout_at).await;
    assert_eq!(expired.len(), 2);
    assert!(expired.iter().all(|timeout| timeout.ordered_channel_failed));
    assert_eq!(manager.incoming_state_counts().await, (0, 0, 0));
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([42; MESSAGE_ID_BYTES]),
                1,
                timeout_at,
            )
            .await,
        DedupDecision::ChannelFailed
    );
    manager.close_peer("peer-a").await;
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([42; MESSAGE_ID_BYTES]),
                1,
                timeout_at,
            )
            .await,
        DedupDecision::New
    );
}

#[tokio::test]
async fn closing_session_clears_active_incoming_and_ordered_buffer() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    for (sequence, id) in [(0, 50), (1, 51)] {
        let message = ordered_message(sequence, id);
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        let result = manager.accept_ordered(message).await;
        assert!(matches!(
            result,
            OrderedInsertResult::Ready | OrderedInsertResult::Buffered
        ));
    }
    manager.close_peer("peer-a").await;
    assert_eq!(manager.incoming_state_counts().await, (0, 0, 0));
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                MessageId([50; MESSAGE_ID_BYTES]),
                1,
                now + Duration::from_secs(1),
            )
            .await,
        DedupDecision::New
    );
}

/// 把发送端 pending 消息转换为接收端 OrderedMessage（message_id 必须一致，
/// 才能命中 begin_incoming 创建的 active dedup 记录）。
fn ordered_from_pending(message: &PendingMessage) -> OrderedMessage {
    OrderedMessage {
        peer_id: message.peer_id.clone(),
        session_id: "session-a".into(),
        channel_id: message.channel_id.clone(),
        message_id: message.message_id,
        sequence: message.sequence,
        policy: message.policy,
        payload: message.payload.clone(),
    }
}

#[tokio::test]
async fn explicit_close_preserves_ordered_anchor_and_resumes_without_wedge() {
    // §40 显式断开：close_peer 保留有序通道的 expected_sequence 断点，与发送端
    // 保留 next_sequences 计数器对称——两端重连后从各自断点继续。修复前 close_peer
    // 清空 ordered 状态，接收端从 expected_sequence=0 重新开始，而发送端继续发
    // 5、6、7：seq5 因间隔超限被 Rejected，通道永久卡死且 expire_incoming 不失败
    // （OrderedBuffered 无 ack_deadline），静默丢消息。
    let manager = DeliveryManager::with_config(DeliveryConfig {
        max_pending_messages: 16,
        max_pending_bytes: 64,
        ..config()
    });
    let now = Instant::now();

    // 发送端入队有序消息 seq 0..5；seq5 是断线时仍 pending（未 ACK）的消息。
    let mut pending = Vec::new();
    for sequence in 0..6u64 {
        pending.push(
            manager
                .enqueue_at(
                    "peer-a",
                    "control",
                    vec![sequence as u8],
                    DeliveryPolicy::SessionBoundOrdered,
                    retry_policy(),
                    now,
                )
                .await
                .expect("enqueue ordered message"),
        );
    }

    // 接收端投递 seq 0..4 → expected_sequence 推进到 5。
    for message in pending.iter().take(5) {
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    1,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(ordered_from_pending(message)).await,
            OrderedInsertResult::Ready
        );
        manager
            .complete_incoming(&message.peer_id, &message.channel_id, message.message_id)
            .await
            .expect("delivered ordered message");
    }

    // 断线：seq5 仍 pending，可经 MessageId 重发（发送端 next_sequences 不受
    // close_peer 影响，新的入队继续从 6 编号）。
    assert_eq!(manager.pending_len().await, 6);
    let resent = manager
        .begin_send(pending[5].message_id, now)
        .await
        .expect("begin resend")
        .expect("resendable");
    assert_eq!(resent.message_id, pending[5].message_id);

    // 双方显式断开：close_peer 放弃在途 dedup/历史/失败标记，但保留有序断点；
    // 本单实例中一次调用同时模拟发送端（next_sequences 保留）与接收端
    // （expected_sequence 保留）两侧的清理。
    manager.close_peer("peer-a").await;

    // 重连：发送端新入队 seq 6、7。
    for sequence in 6..8u64 {
        pending.push(
            manager
                .enqueue_at(
                    "peer-a",
                    "control",
                    vec![sequence as u8],
                    DeliveryPolicy::SessionBoundOrdered,
                    retry_policy(),
                    now,
                )
                .await
                .expect("enqueue new ordered message"),
        );
    }

    // 接收端重建 dedup 记录并把 seq5 重新插入保留的 ordered 状态 → 必须 Ready，
    // 修复前因 expected_sequence 被重置为 0、间隔超限而被 Rejected，通道卡死。
    let surviving = &pending[5];
    assert_eq!(
        manager
            .begin_incoming(
                &surviving.peer_id,
                &surviving.channel_id,
                surviving.message_id,
                2,
                now,
            )
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager
            .accept_ordered(ordered_from_pending(surviving))
            .await,
        OrderedInsertResult::Ready
    );

    // seq6、7 缓冲，seq5 ACK 后按序释放 5、6、7，无空洞。
    for message in pending.iter().skip(6) {
        assert_eq!(
            manager
                .begin_incoming(
                    &message.peer_id,
                    &message.channel_id,
                    message.message_id,
                    2,
                    now,
                )
                .await,
            DedupDecision::New
        );
        assert_eq!(
            manager.accept_ordered(ordered_from_pending(message)).await,
            OrderedInsertResult::Buffered
        );
    }
    let mut released = Vec::new();
    for message in pending.iter().skip(5) {
        let completion = manager
            .complete_incoming(&message.peer_id, &message.channel_id, message.message_id)
            .await
            .expect("ordered message must be ACKable after reconnect");
        released.push(message.sequence);
        if let Some(next) = completion.next_ordered {
            assert_eq!(next.sequence, message.sequence.saturating_add(1));
        }
    }
    assert_eq!(released, vec![5, 6, 7]);
}

#[tokio::test]
async fn recovery_preserves_sequence_and_rejects_stale_ack() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let first = manager
        .enqueue_at(
            "peer-a",
            "control",
            b"one".to_vec(),
            DeliveryPolicy::AckedDeduplicated,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue first");
    let second = manager
        .enqueue_at(
            "peer-a",
            "control",
            b"two".to_vec(),
            DeliveryPolicy::SessionBoundOrdered,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue second");
    assert_eq!(first.sequence, 0);
    assert_eq!(second.sequence, 1);

    let sent = manager
        .begin_send(first.message_id, now)
        .await
        .expect("begin send")
        .expect("sendable");
    assert_eq!(sent.attempts, 1);
    assert_eq!(sent.payload, b"one");
    assert!(manager.mark_sent(first.message_id, now).await);

    let recovery = manager
        .recover_peer_at("peer-a", now + Duration::from_secs(1))
        .await;
    assert_eq!(recovery.recovery_epoch, 1);
    assert_eq!(
        recovery
            .messages
            .iter()
            .map(|message| message.sequence)
            .collect::<Vec<_>>(),
        vec![0, 1]
    );
    // §20：ACK 只按 MessageId 关联——即使携带了过时/未对齐的连接代数，
    // 只要该 MessageId 仍在 pending 中就完成；recover 后以同一 MessageId
    // 重发，ACK 不需要等待 epoch 对齐。
    let resent = manager
        .begin_send(first.message_id, now + Duration::from_secs(1))
        .await
        .expect("begin resend")
        .expect("resendable");
    assert_eq!(resent.recovery_epoch, recovery.recovery_epoch);
    assert_eq!(resent.attempts, 2);
    assert_eq!(
        manager.acknowledge("peer-a", first.message_id).await,
        AckResult::Acknowledged
    );
    assert_eq!(manager.pending_len().await, 1);
    // 已完成 MessageId 的重复 ACK 是无害的 no-op（不再报 StaleEpoch）。
    assert_eq!(
        manager.acknowledge("peer-a", first.message_id).await,
        AckResult::Unknown
    );
}

#[tokio::test]
async fn pending_message_keeps_plaintext_for_retry() {
    let manager = DeliveryManager::with_config(config());
    let message = manager
        .enqueue(
            "peer-a",
            "control",
            b"plaintext".to_vec(),
            DeliveryPolicy::Acked,
            retry_policy(),
        )
        .await
        .expect("enqueue message");
    assert_eq!(message.payload, b"plaintext");
    let sent = manager
        .begin_send(message.message_id, Instant::now())
        .await
        .expect("begin send")
        .expect("sendable");
    assert_eq!(sent.payload, b"plaintext");
}

#[tokio::test]
async fn retry_policy_is_bounded_and_expiry_removes_pending() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message = manager
        .enqueue_at(
            "peer-a",
            "control",
            b"payload".to_vec(),
            DeliveryPolicy::Acked,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue");
    manager
        .begin_send(message.message_id, now)
        .await
        .expect("begin")
        .expect("sendable");
    assert!(manager.mark_sent(message.message_id, now).await);
    assert!(manager
        .retryable_messages("peer-a", now + Duration::from_millis(999))
        .await
        .is_empty());
    assert_eq!(
        manager
            .retryable_messages("peer-a", now + Duration::from_secs(1))
            .await
            .len(),
        1
    );
    assert_eq!(
        manager
            .mark_send_failed(message.message_id, now + Duration::from_secs(1))
            .await,
        RetryDecision::RetryAt(now + Duration::from_secs(2))
    );
    assert_eq!(
        manager
            .recover_peer_at("peer-a", now + Duration::from_secs(31))
            .await
            .messages
            .len(),
        0
    );
    assert_eq!(manager.pending_len().await, 0);
}

#[tokio::test]
async fn latest_state_replaces_only_older_latest_state() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let old = manager
        .enqueue_at(
            "peer-a",
            "mouse",
            vec![1],
            DeliveryPolicy::LatestState,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue old");
    let new = manager
        .enqueue_at(
            "peer-a",
            "mouse",
            vec![2],
            DeliveryPolicy::LatestState,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue new");
    assert_eq!(manager.pending_len().await, 1);
    assert!(matches!(
        manager.begin_send(old.message_id, now).await,
        Err(DeliveryError::NotFound)
    ));
    assert_eq!(
        manager
            .begin_send(new.message_id, now)
            .await
            .expect("begin new")
            .expect("new sendable")
            .payload,
        vec![2]
    );
}

#[tokio::test]
async fn dedup_window_is_scoped_and_expires() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message_id = MessageId([7; MESSAGE_ID_BYTES]);
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::DuplicateInFlight
    );
    assert!(manager
        .complete_incoming("peer-a", "control", message_id)
        .await
        .is_some());
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::DuplicateProcessed
    );
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 2, now)
            .await,
        DedupDecision::DuplicateProcessed
    );
    assert_eq!(
        manager
            .incoming_recovery_epoch("peer-a", "control", message_id)
            .await,
        Some(2)
    );
    // §20：连接代数不再门控去重——携带较低代数的重放帧仍是 DuplicateProcessed，
    // 只是不能再次进入应用 handler（对已完成消息的重复 ACK 是无害 no-op）。
    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::DuplicateProcessed
    );
    assert!(manager
        .complete_incoming("peer-a", "control", message_id)
        .await
        .is_none());
    assert_eq!(
        manager
            .begin_incoming("peer-b", "control", message_id, 1, now)
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                message_id,
                1,
                now + Duration::from_secs(11),
            )
            .await,
        DedupDecision::New
    );
}

#[tokio::test]
async fn recovery_epoch_updates_do_not_turn_inflight_into_processed() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message_id = MessageId([8; MESSAGE_ID_BYTES]);

    assert_eq!(
        manager
            .begin_incoming("peer-a", "control", message_id, 1, now)
            .await,
        DedupDecision::New
    );
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                message_id,
                2,
                now + Duration::from_secs(1),
            )
            .await,
        DedupDecision::DuplicateInFlight
    );
    assert_eq!(
        manager
            .incoming_recovery_epoch("peer-a", "control", message_id)
            .await,
        Some(2)
    );
    assert_eq!(
        manager
            .complete_incoming("peer-a", "control", message_id)
            .await,
        Some(IncomingCompletion {
            recovery_epoch: 2,
            next_ordered: None,
        })
    );
    assert_eq!(
        manager
            .begin_incoming(
                "peer-a",
                "control",
                message_id,
                2,
                now + Duration::from_secs(1),
            )
            .await,
        DedupDecision::DuplicateProcessed
    );
}

#[tokio::test]
async fn best_effort_skips_pending_and_reliable_queue_is_bounded() {
    let manager = DeliveryManager::with_config(DeliveryConfig {
        max_pending_messages: 1,
        max_pending_bytes: 4,
        max_payload_bytes: 4,
        dedup_max_entries: 4,
        dedup_ttl: Duration::from_secs(10),
        application_ack_timeout: Duration::from_secs(5 * 60),
        max_reorder_messages: 2,
        max_reorder_bytes: 8,
        max_sequence_gap: 4,
    });
    let now = Instant::now();
    let best_effort = manager
        .enqueue_at(
            "peer-a",
            "video",
            vec![1, 2, 3, 4],
            DeliveryPolicy::BestEffort,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue best effort");
    assert_eq!(manager.pending_len().await, 0);
    assert!(matches!(
        manager.begin_send(best_effort.message_id, now).await,
        Err(DeliveryError::NotFound)
    ));

    manager
        .enqueue_at(
            "peer-a",
            "control",
            vec![9, 9, 9, 9],
            DeliveryPolicy::Acked,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue reliable");
    assert!(matches!(
        manager
            .enqueue_at(
                "peer-a",
                "control",
                vec![8],
                DeliveryPolicy::Acked,
                retry_policy(),
                now,
            )
            .await,
        Err(DeliveryError::QueueFull)
    ));
}

#[tokio::test]
async fn peer_scoped_send_lease_and_terminal_outcome_are_idempotent() {
    let manager = DeliveryManager::with_config(DeliveryConfig {
        max_pending_messages: 4,
        max_pending_bytes: 32,
        max_payload_bytes: 16,
        ..config()
    });
    let now = Instant::now();
    let message = manager
        .enqueue_at(
            "peer-a",
            "control",
            b"payload".to_vec(),
            DeliveryPolicy::Acked,
            RetryPolicy {
                max_attempts: 1,
                ..retry_policy()
            },
            now,
        )
        .await
        .expect("enqueue");

    assert!(matches!(
        manager
            .begin_send_for_peer("peer-b", message.message_id, now)
            .await,
        Err(DeliveryError::InvalidScope)
    ));
    let attempt = manager
        .begin_send_for_peer("peer-a", message.message_id, now)
        .await
        .expect("begin peer-scoped send")
        .expect("first attempt");
    assert!(manager
        .begin_send_for_peer("peer-a", message.message_id, now)
        .await
        .expect("second lease query")
        .is_none());

    assert_eq!(
        manager.mark_send_failed_for_attempt(&attempt, now).await,
        RetryDecision::Failed
    );
    assert_eq!(
        manager.terminal_outcome("peer-a", message.message_id).await,
        Some(DeliveryTerminalOutcome::Failed)
    );
    assert_eq!(
        manager.mark_send_failed_for_attempt(&attempt, now).await,
        RetryDecision::NotFound
    );
    assert_eq!(
        manager.terminal_outcome("peer-b", message.message_id).await,
        None
    );
}

#[test]
fn delivery_identity_requires_peer_scope_and_excludes_session() {
    let message_id = MessageId([7; MESSAGE_ID_BYTES]);
    let identity = DeliveryIdentity::new("peer-a", message_id).expect("identity");
    assert_eq!(identity.peer_id, "peer-a");
    assert_eq!(identity.message_id, message_id);
    assert_ne!(
        identity,
        DeliveryIdentity::new("peer-b", message_id).expect("peer-scoped identity")
    );
    assert_eq!(
        DeliveryIdentity::new("", message_id),
        Err(DeliveryError::InvalidScope)
    );
}

#[tokio::test]
async fn pending_and_terminal_delivery_keys_include_peer() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message_id = MessageId([9; MESSAGE_ID_BYTES]);
    let mut store = manager.store.lock().await;
    for peer_id in ["peer-a", "peer-b"] {
        let message = PendingMessage {
            message_id,
            peer_id: peer_id.to_string(),
            channel_id: "control".to_string(),
            sequence: 0,
            payload: vec![1, 2, 3],
            policy: DeliveryPolicy::Acked,
            state: DeliveryState::Queued,
            attempts: 0,
            created_at: now,
            expires_at: None,
            recovery_epoch: 0,
            retry_policy: retry_policy(),
            next_retry_at: now,
            retry_bytes: 0,
        };
        store.pending_bytes += message.payload.len();
        store.pending.insert(
            DeliveryIdentity::new(peer_id, message_id).expect("identity"),
            message,
        );
    }
    drop(store);

    assert_eq!(manager.pending_len().await, 2);
    assert_eq!(
        manager.acknowledge("peer-a", message_id).await,
        AckResult::Acknowledged
    );
    assert_eq!(manager.pending_len().await, 1);
    assert_eq!(
        manager.terminal_outcome("peer-a", message_id).await,
        Some(DeliveryTerminalOutcome::Acknowledged)
    );
    assert_eq!(manager.terminal_outcome("peer-b", message_id).await, None);
    assert_eq!(
        manager.acknowledge("peer-b", message_id).await,
        AckResult::Acknowledged
    );
}

#[tokio::test]
async fn late_send_result_cannot_settle_a_newer_attempt() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message = manager
        .enqueue_at(
            "peer-a",
            "control",
            b"payload".to_vec(),
            DeliveryPolicy::Acked,
            retry_policy(),
            now,
        )
        .await
        .expect("enqueue");
    let first = manager
        .begin_send_for_peer("peer-a", message.message_id, now)
        .await
        .expect("first begin")
        .expect("first attempt");
    assert_eq!(
        manager.mark_send_failed_for_attempt(&first, now).await,
        RetryDecision::RetryAt(now + Duration::from_secs(1))
    );
    let second = manager
        .begin_send_for_peer("peer-a", message.message_id, now + Duration::from_secs(1))
        .await
        .expect("second begin")
        .expect("second attempt");
    assert_ne!(first.attempt, second.attempt);
    assert!(!manager.mark_sent_for_attempt(&first, now).await);
    assert_eq!(
        manager.mark_send_failed_for_attempt(&first, now).await,
        RetryDecision::NotFound
    );
    assert!(manager.mark_sent_for_attempt(&second, now).await);
}

#[tokio::test]
async fn same_message_id_is_scoped_to_peer_for_incoming_ack() {
    let manager = DeliveryManager::with_config(config());
    let now = Instant::now();
    let message_id = MessageId([200; MESSAGE_ID_BYTES]);
    assert_eq!(
        manager
            .begin_incoming_checked("peer-a", "control", message_id, 1, now)
            .await,
        Ok(DedupDecision::New)
    );
    assert_eq!(
        manager
            .begin_incoming_checked("peer-b", "control", message_id, 1, now)
            .await,
        Ok(DedupDecision::New)
    );
    assert!(manager
        .complete_incoming_checked("peer-a", "control", message_id)
        .await
        .expect("peer-a completion")
        .is_some());
    assert!(manager
        .complete_incoming_checked("peer-b", "control", message_id)
        .await
        .expect("peer-b completion")
        .is_some());
    assert_eq!(
        manager
            .begin_incoming_checked("", "control", message_id, 1, now)
            .await,
        Err(DeliveryError::InvalidScope)
    );
}

#[test]
fn delivery_recovery_errors_have_stable_business_names() {
    let _manager = DeliveryManager::default();
    assert_eq!(
        BusinessRecoveryError::RecoverableTransportLoss.to_string(),
        "RecoverableTransportLoss"
    );
    assert_eq!(DeliveryError::InvalidScope.recovery_error(), None);
    assert_eq!(
        DeliveryError::Expired.recovery_error(),
        Some(BusinessRecoveryError::OperationExpired)
    );
    assert_eq!(
        DeliveryError::RetryExhausted.recovery_error(),
        Some(BusinessRecoveryError::OperationExpired)
    );
    assert_eq!(
        RetryDecision::RetryAt(Instant::now()).recovery_error(),
        Some(BusinessRecoveryError::RecoverableTransportLoss)
    );
    assert_eq!(
        RetryDecision::Failed.recovery_error(),
        Some(BusinessRecoveryError::OperationExpired)
    );
    assert_eq!(
        RetryDecision::Expired.recovery_error(),
        Some(BusinessRecoveryError::OperationExpired)
    );
    assert_eq!(RetryDecision::NotFound.recovery_error(), None);
}
