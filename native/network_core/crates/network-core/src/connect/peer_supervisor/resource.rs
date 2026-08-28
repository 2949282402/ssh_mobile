//! Owning peer-scoped resource lease.

use super::*;

/// An owning reservation for one peer-scoped resource.
pub(crate) struct PeerResourceLease {
    pub(super) supervisor: Arc<PeerSupervisor>,
    pub(super) resource_id: u64,
}

impl Drop for PeerResourceLease {
    fn drop(&mut self) {
        self.supervisor.release_resource(self.resource_id);
    }
}
