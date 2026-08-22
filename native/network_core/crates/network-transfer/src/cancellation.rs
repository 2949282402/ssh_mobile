use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Clone, Default)]
pub struct TransferCancellation {
    cancelled: Arc<AtomicBool>,
}

impl TransferCancellation {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
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
}
