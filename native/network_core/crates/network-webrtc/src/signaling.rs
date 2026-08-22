use std::fmt;

use thiserror::Error;

pub const MAX_SDP_BYTES: usize = 256 * 1024;
pub const MAX_ICE_CANDIDATE_BYTES: usize = 8 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DescriptionType {
    Offer,
    Answer,
}

impl fmt::Display for DescriptionType {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Offer => "offer",
            Self::Answer => "answer",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionDescription {
    pub kind: DescriptionType,
    pub sdp: String,
}

impl SessionDescription {
    pub fn new(kind: DescriptionType, sdp: String) -> Result<Self, SignalingError> {
        if sdp.is_empty() {
            return Err(SignalingError::EmptyDescription);
        }
        if sdp.len() > MAX_SDP_BYTES {
            return Err(SignalingError::DescriptionTooLarge);
        }
        if !sdp.starts_with("v=0") {
            return Err(SignalingError::InvalidDescription);
        }
        Ok(Self { kind, sdp })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IceCandidate {
    pub candidate: String,
    pub sdp_mid: Option<String>,
    pub sdp_mline_index: Option<u16>,
    pub username_fragment: Option<String>,
}

impl IceCandidate {
    pub fn new(
        candidate: String,
        sdp_mid: Option<String>,
        sdp_mline_index: Option<u16>,
        username_fragment: Option<String>,
    ) -> Result<Self, SignalingError> {
        if candidate.len() > MAX_ICE_CANDIDATE_BYTES {
            return Err(SignalingError::CandidateTooLarge);
        }
        if !candidate.is_empty() && !candidate.starts_with("candidate:") {
            return Err(SignalingError::InvalidCandidate);
        }
        Ok(Self {
            candidate,
            sdp_mid,
            sdp_mline_index,
            username_fragment,
        })
    }

    pub fn end_of_candidates() -> Self {
        Self {
            candidate: String::new(),
            sdp_mid: None,
            sdp_mline_index: None,
            username_fragment: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalingState {
    New,
    LocalOffer,
    RemoteOffer,
    LocalAnswer,
    Connected,
    Restarting,
    Closed,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum SignalingError {
    #[error("SDP description is empty")]
    EmptyDescription,
    #[error("SDP description exceeds the size limit")]
    DescriptionTooLarge,
    #[error("SDP description must start with v=0")]
    InvalidDescription,
    #[error("ICE candidate exceeds the size limit")]
    CandidateTooLarge,
    #[error("ICE candidate has an invalid prefix")]
    InvalidCandidate,
    #[error("invalid WebRTC signaling transition from {0:?}")]
    InvalidTransition(SignalingState),
}

#[derive(Debug, Clone)]
pub struct SignalingStateMachine {
    state: SignalingState,
    revision: u64,
}

impl Default for SignalingStateMachine {
    fn default() -> Self {
        Self {
            state: SignalingState::New,
            revision: 0,
        }
    }
}

impl SignalingStateMachine {
    pub fn state(&self) -> SignalingState {
        self.state
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn local_offer(&mut self) -> Result<(), SignalingError> {
        self.transition(
            &[
                SignalingState::New,
                SignalingState::Connected,
                SignalingState::Restarting,
            ],
            SignalingState::LocalOffer,
        )
    }

    pub fn remote_offer(&mut self) -> Result<(), SignalingError> {
        self.transition(
            &[
                SignalingState::New,
                SignalingState::Connected,
                SignalingState::Restarting,
                SignalingState::LocalAnswer,
            ],
            SignalingState::RemoteOffer,
        )
    }

    pub fn local_answer(&mut self) -> Result<(), SignalingError> {
        self.transition(&[SignalingState::RemoteOffer], SignalingState::LocalAnswer)
    }

    pub fn remote_answer(&mut self) -> Result<(), SignalingError> {
        self.transition(&[SignalingState::LocalOffer], SignalingState::Connected)
    }

    pub fn restart(&mut self) -> Result<(), SignalingError> {
        if self.state == SignalingState::Closed {
            return Err(SignalingError::InvalidTransition(self.state));
        }
        self.state = SignalingState::Restarting;
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }

    pub fn close(&mut self) {
        self.state = SignalingState::Closed;
    }

    fn transition(
        &mut self,
        allowed: &[SignalingState],
        next: SignalingState,
    ) -> Result<(), SignalingError> {
        if !allowed.contains(&self.state) {
            return Err(SignalingError::InvalidTransition(self.state));
        }
        self.state = next;
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }
}

#[cfg(test)]
#[path = "tests/signaling.rs"]
mod tests;
