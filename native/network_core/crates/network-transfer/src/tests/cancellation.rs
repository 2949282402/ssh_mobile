use super::*;

#[test]
fn cancellation_is_shared_and_idempotent() {
    let cancellation = TransferCancellation::default();
    let clone = cancellation.clone();
    assert!(!cancellation.is_cancelled());
    clone.cancel();
    assert!(cancellation.is_cancelled());
    cancellation.cancel();
    assert!(clone.is_cancelled());
}
