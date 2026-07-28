//! QUIC file transfer protocol, manifests, streaming chunks, checksums, and resume.

pub mod cancellation;
pub mod manager;
pub mod manifest;
pub mod receiver;
pub mod sender;

pub use cancellation::TransferCancellation;
pub use manager::TransferManager;
pub use manifest::{
    FileManifest, ResumeRequest, TransferAccept, TransferOffer, TransferReject,
    DEFAULT_TRANSFER_BUFFER, NETWORK_TRANSFER_PROTOCOL_VERSION,
};
pub use receiver::{stream_receive_file, stream_receive_file_cancellable};
pub use sender::{build_file_manifest, stream_send_file, stream_send_file_cancellable};
