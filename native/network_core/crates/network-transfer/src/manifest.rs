pub const DEFAULT_TRANSFER_BUFFER: usize = 512 * 1024; // 512 KiB
pub const NETWORK_TRANSFER_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone)]
pub struct FileManifest {
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub modified_at: i64,
    pub content_hash: String,
    pub protocol_version: u32,
}

impl FileManifest {
    pub fn validate(&self) -> Result<(), String> {
        if self.transfer_id.is_empty()
            || self.transfer_id.len() > 128
            || !self
                .transfer_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        {
            return Err("transfer_id contains unsafe characters".into());
        }
        if self.file_name.is_empty()
            || self.file_name.len() > 255
            || self.file_name.contains(['/', '\\'])
            || std::path::Path::new(&self.file_name).components().count() != 1
            || matches!(
                std::path::Path::new(&self.file_name).components().next(),
                Some(std::path::Component::ParentDir | std::path::Component::CurDir)
            )
        {
            return Err("file_name must be a single safe path component".into());
        }
        if self.content_hash.len() != 64
            || !self
                .content_hash
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
        {
            return Err("content_hash must be a SHA-256 hex digest".into());
        }
        if self.protocol_version != NETWORK_TRANSFER_PROTOCOL_VERSION {
            return Err("unsupported transfer protocol version".into());
        }
        Ok(())
    }
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
