use super::*;
use std::sync::atomic::AtomicUsize;
use std::time::Duration;

#[tokio::test]
async fn session_and_runtime_tasks_are_cancelled_and_joined() {
    let supervisor = RuntimeTaskSupervisor::new();
    let runtime_exits = Arc::new(AtomicUsize::new(0));
    let session_exits = Arc::new(AtomicUsize::new(0));
    let runtime_exits_for_task = Arc::clone(&runtime_exits);
    let session_exits_for_task = Arc::clone(&session_exits);
    supervisor.spawn_runtime("runtime-test", async move {
        std::future::pending::<()>().await;
        runtime_exits_for_task.fetch_add(1, Ordering::Relaxed);
    });
    supervisor.spawn_session("session-1", "session-test", async move {
        std::future::pending::<()>().await;
        session_exits_for_task.fetch_add(1, Ordering::Relaxed);
    });
    tokio::time::sleep(Duration::from_millis(5)).await;
    assert_eq!(supervisor.active_count(), 2);

    supervisor.cancel_session("session-1").await;
    assert_eq!(supervisor.active_count(), 1);
    supervisor.shutdown().await;
    assert_eq!(supervisor.active_count(), 0);
    assert_eq!(runtime_exits.load(Ordering::Relaxed), 0);
    assert_eq!(session_exits.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn cancellation_interrupts_a_sleeping_task() {
    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_runtime("sleeping", async {
        tokio::time::sleep(Duration::from_secs(60)).await;
    });
    tokio::task::yield_now().await;
    let started = std::time::Instant::now();
    supervisor.shutdown().await;
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[tokio::test]
async fn cancellation_tokens_are_idempotent_and_immediately_observable() {
    let token = CancellationToken::default();

    token.cancel();
    token.cancel();

    assert!(token.is_cancelled());
    token.cancelled().await;
}

#[tokio::test]
async fn controlled_task_leases_cancel_idempotently_and_abort_on_drop() {
    let supervisor = RuntimeTaskSupervisor::new();
    let mut lease = supervisor
        .spawn_session_controlled("lease", "cancel", std::future::pending::<()>())
        .expect("controlled task should be admitted");

    lease.cancel().await;
    lease.cancel().await;
    assert_eq!(supervisor.active_count(), 0);

    let dropped = supervisor
        .spawn_session_controlled("lease", "drop", std::future::pending::<()>())
        .expect("second controlled task should be admitted");
    drop(dropped);
    assert_eq!(supervisor.active_count(), 0);
    supervisor.shutdown().await;
}

#[tokio::test]
async fn cancelled_session_group_rejects_new_children_and_missing_session_is_noop() {
    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_session("group", "existing", std::future::pending::<()>());
    let group = supervisor
        .session_groups
        .lock()
        .expect("session groups lock")
        .get("group")
        .cloned()
        .expect("group should exist");

    group.token.cancel();
    assert!(supervisor
        .spawn_session("group", "rejected", std::future::pending::<()>())
        .is_none());
    supervisor.cancel_session("missing").await;
    supervisor.shutdown().await;
}

#[tokio::test]
async fn session_admission_rechecks_group_cancellation_after_task_spawn() {
    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_session("race", "existing", std::future::pending::<()>());
    let group = supervisor
        .session_groups
        .lock()
        .expect("session groups lock")
        .get("race")
        .cloned()
        .expect("group should exist");
    let task_ids_guard = group.task_ids.lock().expect("task ids lock");

    let supervisor_for_thread = Arc::clone(&supervisor);
    let runtime_handle = tokio::runtime::Handle::current();
    let admission = std::thread::spawn(move || {
        let _runtime_guard = runtime_handle.enter();
        supervisor_for_thread.spawn_session("race", "racing", std::future::pending::<()>())
    });

    let mut admitted = false;
    for _ in 0..100 {
        if supervisor.active_count() >= 2 {
            admitted = true;
            break;
        }
        std::thread::yield_now();
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(admitted, "racing child should reach the session registry");
    group.token.cancel();
    drop(task_ids_guard);

    assert!(admission
        .join()
        .expect("admission thread should finish")
        .is_none());
    supervisor.shutdown().await;
}

#[tokio::test]
async fn shutdown_and_abort_paths_are_idempotent() {
    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_session("shutdown", "child", std::future::pending::<()>());
    supervisor.shutdown().await;
    supervisor.shutdown().await;
    assert_eq!(supervisor.active_count(), 0);

    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_runtime("abort", std::future::pending::<()>());
    supervisor.spawn_session("abort-session", "child", std::future::pending::<()>());
    supervisor.abort_all_now();
    assert_eq!(supervisor.active_count(), 0);
    supervisor.abort_all_now();
}

#[tokio::test]
async fn supervisor_rejects_tasks_at_the_live_capacity() {
    let supervisor = RuntimeTaskSupervisor::new();
    for task_number in 0..MAX_SUPERVISED_TASKS {
        assert!(supervisor
            .spawn_runtime(
                format!("capacity-{task_number}"),
                std::future::pending::<()>()
            )
            .is_some());
    }

    assert!(supervisor
        .spawn_runtime("capacity-overflow", std::future::pending::<()>())
        .is_none());
    supervisor.shutdown().await;
}

#[tokio::test]
async fn finished_tasks_are_reaped_before_counting_active_records() {
    let supervisor = RuntimeTaskSupervisor::new();
    supervisor.spawn_runtime("finished", async {});
    tokio::task::yield_now().await;
    assert_eq!(supervisor.active_count(), 0);

    let join = tokio::spawn(async {});
    join_record(Arc::new(TaskRecord {
        token: CancellationToken::default(),
        join: Mutex::new(Some(join)),
    }))
    .await;
}
