//! ConnectionSession security admission for transport-network v2.
//!
//! A transport connection gets a fresh SessionId and a fresh crypto root. This
//! module records only the identity and security-admission facts needed to
//! install that connection: a pending session reservation, the authenticated
//! remote binding, and the single-winner guard for racing candidates.
//!
//! Peer lifecycle, physical paths, route/carrier ownership, and business
//! recovery do not belong here. In particular, this store never exposes a
//! current route or carrier and never decides whether a Peer is Connecting,
//! Online, Offline, or ready for a business capability.

use rand::{rngs::OsRng, RngCore};
use std::collections::HashMap;
use std::ops::Deref;
use tokio::sync::RwLock;

/// Identity of one transport ConnectionSession.
///
/// The value is intentionally fresh for every new transport connection. It
/// must not be used as a peer lifecycle or business-recovery identity.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) struct SessionId([u8; SESSION_ID_BYTES]);

pub(crate) const SESSION_ID_BYTES: usize = 16;

impl SessionId {
    /// Allocate a cryptographically random connection/session identity.
    pub(crate) fn new() -> Self {
        let mut bytes = [0u8; SESSION_ID_BYTES];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }

    /// Test-only construction for deterministic identity assertions.
    #[cfg(test)]
    pub(crate) fn from_bytes(bytes: [u8; SESSION_ID_BYTES]) -> Self {
        Self(bytes)
    }

    /// Delivery and transfer code may use this as an opaque correlation key.
    /// It is not a route key and does not imply session continuity.
    pub(crate) fn wire_key(self) -> String {
        hex::encode(self.0)
    }
}

/// Security decision for installing fresh connection crypto.
///
/// Both variants require a new crypto root. ReplaceWithNew is used only when
/// an unaffiliated authenticated connection proves a new remote runtime
/// binding; it is not a peer lifecycle replacement state machine.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SessionCryptoDecision {
    Initialize,
    ReplaceWithNew,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConnectionAdmission {
    pub(crate) session_id: SessionId,
    pub(crate) decision: SessionCryptoDecision,
    pub(crate) replaced_session_id: Option<SessionId>,
}

/// Result of one authenticated connection admission.
///
/// The store returns no route, carrier, stream, or relay owner. Those
/// resources are admitted and released by their owning path/connection
/// subsystem after this security decision succeeds.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConnectionAdmissionOutcome {
    pub(crate) admission: ConnectionAdmission,
}

impl Deref for ConnectionAdmissionOutcome {
    type Target = ConnectionAdmission;

    fn deref(&self) -> &Self::Target {
        &self.admission
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ConnectionAdmissionError {
    StaleSession,
    InvalidRemoteBinding,
}

/// Security-only phase for one connection identity.
///
/// Reserved means a caller has supplied the identity for a connection
/// attempt. Claimed is the winner of the authenticated-candidate race but has
/// not necessarily completed the post-Noise root exchange. Authenticated is
/// the finalized binding. The phases are deliberately not Peer lifecycle
/// states.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AdmissionPhase {
    Reserved,
    Claimed,
    Authenticated,
}

struct SessionAdmission {
    id: SessionId,
    remote_session_binding: Option<String>,
    phase: AdmissionPhase,
}

/// Stores connection/security admission facts only.
///
/// The map is keyed by peer for the duration of the current connection
/// admission. It does not own a socket, path, carrier, stream, relay data
/// client, timer, task, or Peer lifecycle state.
pub(crate) struct ConnectionSessionStore {
    sessions: RwLock<HashMap<String, SessionAdmission>>,
}

impl ConnectionSessionStore {
    pub(crate) fn new() -> Self {
        Self {
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// Register a fresh connection identity selected by the Peer/attempt
    /// owner. The caller decides when an old admission is retired; this method
    /// never replaces one as a side effect.
    pub(crate) async fn register_pending_session(
        &self,
        peer_id: &str,
        session_id: SessionId,
    ) -> Result<(), ConnectionAdmissionError> {
        let mut sessions = self.sessions.write().await;
        if sessions.contains_key(peer_id) {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        sessions.insert(
            peer_id.to_string(),
            SessionAdmission {
                id: session_id,
                remote_session_binding: None,
                phase: AdmissionPhase::Reserved,
            },
        );
        Ok(())
    }

    /// Return the currently admitted connection identity for security
    /// correlation. This says nothing about Peer online/offline state.
    pub(crate) async fn current_session_id(&self, peer_id: &str) -> Option<SessionId> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .map(|session| session.id)
    }

    /// Return the authenticated remote binding kept for the current
    /// connection. The binding is identity/admission data, not route truth.
    pub(crate) async fn current_remote_session_binding(&self, peer_id: &str) -> Option<String> {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .and_then(|session| session.remote_session_binding.clone())
    }

    /// Check a stale guard without making a lifecycle decision.
    #[allow(dead_code)] // admission diagnostics query surface
    pub(crate) async fn is_current_session(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
    ) -> bool {
        self.sessions
            .read()
            .await
            .get(peer_id)
            .is_some_and(|session| session.id == expected_session_id)
    }

    /// Admit the authenticated remote binding and claim the candidate winner.
    ///
    /// The write lock covers the complete check-and-claim operation:
    ///
    /// - a pending expected session keeps its fresh SessionId;
    /// - a responder with no pending session creates a fresh SessionId;
    /// - a second candidate for an already claimed binding is stale;
    /// - an unaffiliated candidate with a different remote binding gets a
    ///   fresh SessionId and fresh crypto decision;
    /// - an expected session can never be replaced after another candidate has
    ///   claimed it.
    ///
    /// Candidate capabilities are intentionally absent. Path selection and
    /// business requirements are owned by their callers.
    pub(crate) async fn admit_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: Option<SessionId>,
        new_remote_binding: &str,
    ) -> Result<ConnectionAdmissionOutcome, ConnectionAdmissionError> {
        if new_remote_binding.is_empty() {
            return Err(ConnectionAdmissionError::InvalidRemoteBinding);
        }

        let mut sessions = self.sessions.write().await;
        let Some(current) = sessions.get_mut(peer_id) else {
            if expected_session_id.is_some() {
                return Err(ConnectionAdmissionError::StaleSession);
            }
            let session_id = SessionId::new();
            sessions.insert(
                peer_id.to_string(),
                SessionAdmission {
                    id: session_id,
                    remote_session_binding: Some(new_remote_binding.to_string()),
                    phase: AdmissionPhase::Claimed,
                },
            );
            return Ok(ConnectionAdmissionOutcome {
                admission: ConnectionAdmission {
                    session_id,
                    decision: SessionCryptoDecision::Initialize,
                    replaced_session_id: None,
                },
            });
        };

        if expected_session_id.is_some_and(|expected| expected != current.id) {
            return Err(ConnectionAdmissionError::StaleSession);
        }

        // Once any authenticated candidate has claimed the binding, every
        // later candidate is a loser, including a candidate with the same
        // remote binding. This is the single-winner admission guard.
        if current.remote_session_binding.as_deref() == Some(new_remote_binding) {
            return Err(ConnectionAdmissionError::StaleSession);
        }

        // A caller that supplied an expected identity may claim a reserved
        // identity. A finalized identity with a changed remote binding is the
        // explicit peer-restart case and receives a fresh SessionId; a merely
        // claimed (still in-flight) identity remains single-winner guarded.
        let replaces_existing = if expected_session_id.is_some() {
            match current.phase {
                AdmissionPhase::Reserved => false,
                AdmissionPhase::Authenticated => true,
                AdmissionPhase::Claimed => {
                    return Err(ConnectionAdmissionError::StaleSession);
                }
            }
        } else {
            current.phase != AdmissionPhase::Reserved || current.remote_session_binding.is_some()
        };
        if replaces_existing {
            let replaced_session_id = current.id;
            let session_id = SessionId::new();
            *current = SessionAdmission {
                id: session_id,
                remote_session_binding: Some(new_remote_binding.to_string()),
                phase: AdmissionPhase::Claimed,
            };
            return Ok(ConnectionAdmissionOutcome {
                admission: ConnectionAdmission {
                    session_id,
                    decision: SessionCryptoDecision::ReplaceWithNew,
                    replaced_session_id: Some(replaced_session_id),
                },
            });
        }

        // A responder candidate may claim a reservation created by the local
        // connection owner when no expected id was carried by the inbound
        // handshake. This is still an admission claim, not a Peer state
        // transition.
        current.remote_session_binding = Some(new_remote_binding.to_string());
        current.phase = AdmissionPhase::Claimed;
        Ok(ConnectionAdmissionOutcome {
            admission: ConnectionAdmission {
                session_id: current.id,
                decision: SessionCryptoDecision::Initialize,
                replaced_session_id: None,
            },
        })
    }

    /// Finalize the remote binding after the post-Noise security exchange.
    ///
    /// This operation is idempotent for the same claimed binding, but cannot
    /// rewrite an authenticated binding or revive a stale SessionId.
    pub(crate) async fn finalize_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        remote_session_binding: &str,
    ) -> Result<(), ConnectionAdmissionError> {
        if remote_session_binding.is_empty() {
            return Err(ConnectionAdmissionError::InvalidRemoteBinding);
        }
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return Err(ConnectionAdmissionError::StaleSession);
        };
        if session.id != expected_session_id {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        if session
            .remote_session_binding
            .as_deref()
            .is_some_and(|existing| existing != remote_session_binding)
        {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        if session.phase == AdmissionPhase::Reserved {
            return Err(ConnectionAdmissionError::StaleSession);
        }
        session.remote_session_binding = Some(remote_session_binding.to_string());
        session.phase = AdmissionPhase::Authenticated;
        Ok(())
    }

    /// Release an unfinalized authenticated claim so another candidate can
    /// retry the same reserved connection identity. Finalized security state
    /// must be retired by the connection owner, never silently reopened.
    pub(crate) async fn release_authenticated_session(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
        remote_session_binding: &str,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        let Some(session) = sessions.get_mut(peer_id) else {
            return false;
        };
        if session.id != expected_session_id
            || session.phase != AdmissionPhase::Claimed
            || session.remote_session_binding.as_deref() != Some(remote_session_binding)
        {
            return false;
        }
        session.remote_session_binding = None;
        session.phase = AdmissionPhase::Reserved;
        true
    }

    /// Retire one exact connection admission after transport/security teardown.
    /// The caller owns the associated transport/path cleanup.
    pub(crate) async fn retire_session(
        &self,
        peer_id: &str,
        expected_session_id: SessionId,
    ) -> bool {
        let mut sessions = self.sessions.write().await;
        if sessions
            .get(peer_id)
            .is_some_and(|session| session.id == expected_session_id)
        {
            sessions.remove(peer_id);
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
#[path = "tests/session.rs"]
mod tests;
