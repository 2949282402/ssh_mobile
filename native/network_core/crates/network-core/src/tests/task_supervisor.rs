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
