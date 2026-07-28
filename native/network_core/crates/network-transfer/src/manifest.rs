pub const DEFAULT_TRANSFER_BUFFER: usize = 512 * 1024; // 512 KiB

#[derive(Debug, Clone)]
pub struct FileManifest {
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub modified_at: i64,
    pub content_hash: String,
    pub protocol_version: u32,
}

#[derive(Debug, Clone)]
pub struct TransferOffer {
    pub manifest: FileManifest,
}

#[derive(Debug, Clone)]
pub struct TransferAccept {
    pub transfer_id: String,
    pub offset: u64,
}

#[derive(Debug, Clone)]
pub struct TransferReject {
    pub transfer_id: String,
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct ResumeRequest {
    pub transfer_id: String,
    pub offset: u64,
}
