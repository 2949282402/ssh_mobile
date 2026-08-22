//! Candidate Payload V2 and the resolved remote-candidate cache.
//!
//! The v1 candidate signal still exists at the transport boundary while the
//! migration is in progress, but new code must keep the durable rules here:
//! candidate qualification is explicit, a Relay candidate can never enter a
//! DirectProbe, and remote freshness is based on a native monotonic clock.

use crate::candidate::{Candidate, CandidateKind};
use crate::exchange::RuntimeEpoch;
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

pub const CANDIDATE_PAYLOAD_VERSION: u32 = 2;
pub const DEFAULT_REMOTE_CANDIDATE_CACHE_TTL: Duration = Duration::from_secs(60);
pub const MAX_CANDIDATE_PAYLOAD_ENTRIES: usize = 32;
pub const MAX_CANDIDATE_PAYLOAD_BYTES: usize = 32 * 1024;
pub const MAX_CANDIDATE_ID_BYTES: usize = 128;
pub const MAX_INTERFACE_BYTES: usize = 128;
const MAX_RETIRED_EPOCHS: usize = 8;

/// Transport capability advertised by one physical candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CandidateTransport {
    Quic,
    Tcp,
    Websocket,
    UdpDatagram,
    Relay,
}

impl CandidateTransport {
    fn order(self) -> u8 {
        match self {
            Self::Quic => 0,
            Self::Tcp => 1,
            Self::Websocket => 2,
            Self::UdpDatagram => 3,
            Self::Relay => 4,
        }
    }
}

/// The versioned candidate payload. Relay stores this payload as opaque bytes;
/// native callers validate and qualify it before starting a DirectProbe.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CandidatePayloadV2 {
    pub version: u32,
    pub candidate_id: String,
    pub endpoint: SocketAddr,
    pub kind: CandidateKind,
    pub transport_capabilities: Vec<CandidateTransport>,
    pub priority: u32,
    pub interface: String,
    pub generation: u64,
}

impl CandidatePayloadV2 {
    /// Adapts the legacy in-memory candidate into the versioned payload at the
    /// transport boundary. Callers must supply the capabilities actually
    /// supported by the socket/transport; this method deliberately does not
    /// guess TCP or WebSocket support from an IP endpoint.
    pub fn from_candidate(
        candidate: &Candidate,
        transport_capabilities: Vec<CandidateTransport>,
    ) -> Self {
        Self {
            version: CANDIDATE_PAYLOAD_VERSION,
            candidate_id: candidate.candidate_id.clone(),
            endpoint: candidate.endpoint,
            kind: candidate.kind,
            transport_capabilities,
            priority: candidate.priority,
            interface: candidate.interface_name.clone(),
            generation: candidate.generation,
        }
    }

    pub fn validate(&self) -> Result<(), CandidatePayloadError> {
        if self.version != CANDIDATE_PAYLOAD_VERSION {
            return Err(CandidatePayloadError::UnsupportedVersion(self.version));
        }
        if self.candidate_id.is_empty()
            || self.candidate_id.len() > MAX_CANDIDATE_ID_BYTES
            || !self
                .candidate_id
                .bytes()
                .all(|byte| byte.is_ascii_graphic())
        {
            return Err(CandidatePayloadError::InvalidIdentity);
        }
        if self.interface.is_empty()
            || self.interface.len() > MAX_INTERFACE_BYTES
            || !self.interface.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Err(CandidatePayloadError::InvalidIdentity);
        }
        if self.endpoint.ip().is_unspecified() || self.endpoint.port() == 0 {
            return Err(CandidatePayloadError::InvalidEndpoint);
        }
        if self.transport_capabilities.is_empty() {
            return Err(CandidatePayloadError::MissingTransportCapability);
        }
        let mut seen = Vec::with_capacity(self.transport_capabilities.len());
        for transport in &self.transport_capabilities {
            if seen.contains(transport) {
                return Err(CandidatePayloadError::DuplicateTransport);
            }
            seen.push(*transport);
        }

        if self.generation == 0 {
            return Err(CandidatePayloadError::InvalidGeneration);
        }

        // STUN server-reflexive addresses describe a UDP mapping. Treating a
        // srflx endpoint as a TCP/WS/Relay candidate is both incorrect and a
        // common source of a probe that can never succeed. Use an allow-list,
        // rather than a deny-list, so a future transport cannot silently leak
        // into the srflx path.
        if self.kind == CandidateKind::ServerReflexive
            && self.transport_capabilities.iter().any(|transport| {
                !matches!(
                    transport,
                    CandidateTransport::Quic | CandidateTransport::UdpDatagram
                )
            })
        {
            return Err(CandidatePayloadError::SrflxTransportMismatch);
        }

        // Relay is a fallback topology, not a DirectProbe transport. Keep
        // the invalid combination out of the type boundary so a caller cannot
        // accidentally start a direct task for a Relay candidate.
        if self.kind == CandidateKind::Relay {
            if self
                .transport_capabilities
                .iter()
                .any(|transport| *transport != CandidateTransport::Relay)
            {
                return Err(CandidatePayloadError::RelayTransportMismatch);
            }
        } else if self
            .transport_capabilities
            .contains(&CandidateTransport::Relay)
        {
            return Err(CandidatePayloadError::RelayTransportMismatch);
        }
        Ok(())
    }

    /// Returns a canonical representation for fingerprinting and comparison.
    pub fn normalized(mut self) -> Result<Self, CandidatePayloadError> {
        self.validate()?;
        self.transport_capabilities
            .sort_by_key(|transport| transport.order());
        Ok(self)
    }

    /// Relay candidates are intentionally never eligible for DirectProbe.
    pub fn direct_transports(&self) -> Vec<CandidateTransport> {
        if self.kind == CandidateKind::Relay {
            return Vec::new();
        }
        self.transport_capabilities
            .iter()
            .copied()
            .filter(|transport| !matches!(transport, CandidateTransport::Relay))
            .collect()
    }

    pub fn is_direct_probe_eligible(&self) -> bool {
        self.direct_transports().iter().any(|transport| {
            matches!(
                transport,
                CandidateTransport::Quic
                    | CandidateTransport::Tcp
                    | CandidateTransport::Websocket
                    | CandidateTransport::UdpDatagram
            )
        })
    }

    /// Encodes one candidate as the opaque JSON payload carried by discovery
    /// and connectivity signaling. Validation happens before encoding so a
    /// caller cannot publish a payload that the receiving side would reject.
    pub fn encode(&self) -> Result<Vec<u8>, CandidatePayloadError> {
        let normalized = self.clone().normalized()?;
        let encoded = serde_json::to_vec(&normalized)
            .map_err(|_| CandidatePayloadError::MalformedEncoding)?;
        if encoded.len() > MAX_CANDIDATE_PAYLOAD_BYTES {
            return Err(CandidatePayloadError::CandidatePayloadTooLarge);
        }
        Ok(encoded)
    }

    /// Decodes and validates one opaque candidate payload.
    pub fn decode(bytes: &[u8]) -> Result<Self, CandidatePayloadError> {
        if bytes.len() > MAX_CANDIDATE_PAYLOAD_BYTES {
            return Err(CandidatePayloadError::CandidatePayloadTooLarge);
        }
        let candidate: Self =
            serde_json::from_slice(bytes).map_err(|_| CandidatePayloadError::MalformedEncoding)?;
        candidate.normalized()
    }

    /// Stable key for a single direct attempt. Endpoint and generation are
    /// intentionally part of the key: an update under the same candidate ID
    /// must create a new probe opportunity.
    pub fn attempt_key(&self) -> CandidateAttemptKey {
        CandidateAttemptKey::from_candidate(self)
    }
}

/// The immutable identity used by a DirectProbe queue.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CandidateAttemptKey {
    pub candidate_id: String,
    pub endpoint: SocketAddr,
    pub generation: u64,
}

impl CandidateAttemptKey {
    pub fn from_candidate(candidate: &CandidatePayloadV2) -> Self {
        Self {
            candidate_id: candidate.candidate_id.clone(),
            endpoint: candidate.endpoint,
            generation: candidate.generation,
        }
    }
}

/// A candidate after transport qualification. A DirectProbe should accept
/// this type rather than a raw candidate payload; a Relay candidate produces
/// no value here and therefore cannot start a direct task.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QualifiedDirectCandidate {
    pub candidate: CandidatePayloadV2,
    pub transport: CandidateTransport,
}

impl QualifiedDirectCandidate {
    pub fn attempt_key(&self) -> CandidateAttemptKey {
        self.candidate.attempt_key()
    }
}

/// Qualifies and expands a payload set into DirectProbe inputs. The order is
/// deterministic and preserves candidate order followed by the canonical
/// transport order within each candidate.
pub fn qualify_direct_probe(
    candidates: impl IntoIterator<Item = CandidatePayloadV2>,
) -> Result<Vec<QualifiedDirectCandidate>, CandidatePayloadError> {
    let mut qualified = Vec::new();
    for candidate in candidates {
        let candidate = candidate.normalized()?;
        if candidate.kind == CandidateKind::Relay {
            continue;
        }
        for transport in candidate.direct_transports() {
            qualified.push(QualifiedDirectCandidate {
                candidate: candidate.clone(),
                transport,
            });
        }
    }
    Ok(qualified)
}

/// Deterministic pending queue used by the Coordinator-facing DirectProbe
/// adapter. It owns no socket or task; it only enforces candidate identity,
/// snapshot removal, and same-ID endpoint/generation replacement semantics.
#[derive(Debug, Default)]
pub struct DirectProbeQueue {
    pending: Vec<QualifiedDirectCandidate>,
    started: HashSet<CandidateAttemptKey>,
}

impl DirectProbeQueue {
    /// Reconciles a complete authoritative candidate snapshot. Candidates
    /// removed from the snapshot are removed from `pending`; a changed
    /// endpoint or generation gets a new key and is queued again.
    pub fn reconcile(
        &mut self,
        candidates: impl IntoIterator<Item = CandidatePayloadV2>,
    ) -> Result<(), CandidatePayloadError> {
        let qualified = qualify_direct_probe(candidates)?;
        let snapshot_keys = qualified
            .iter()
            .map(QualifiedDirectCandidate::attempt_key)
            .collect::<HashSet<_>>();
        self.pending
            .retain(|candidate| snapshot_keys.contains(&candidate.attempt_key()));
        for candidate in qualified {
            let key = candidate.attempt_key();
            if !self.started.contains(&key)
                && !self
                    .pending
                    .iter()
                    .any(|pending| pending.attempt_key() == key)
            {
                self.pending.push(candidate);
            }
        }
        Ok(())
    }

    pub fn pop_next(&mut self) -> Option<QualifiedDirectCandidate> {
        let candidate = (!self.pending.is_empty()).then(|| self.pending.remove(0));
        if let Some(candidate) = &candidate {
            self.started.insert(candidate.attempt_key());
        }
        candidate
    }

    pub fn pending(&self) -> &[QualifiedDirectCandidate] {
        &self.pending
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CandidatePayloadError {
    UnsupportedVersion(u32),
    InvalidIdentity,
    InvalidEndpoint,
    MissingTransportCapability,
    DuplicateTransport,
    DuplicateCandidateId,
    InvalidGeneration,
    SrflxTransportMismatch,
    RelayTransportMismatch,
    CandidateSetTooLarge,
    CandidatePayloadTooLarge,
    MalformedEncoding,
}

impl std::fmt::Display for CandidatePayloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedVersion(version) => {
                write!(f, "unsupported candidate payload version {version}")
            }
            Self::InvalidIdentity => f.write_str("candidate identity is invalid"),
            Self::InvalidEndpoint => f.write_str("candidate endpoint is invalid"),
            Self::MissingTransportCapability => {
                f.write_str("candidate has no transport capability")
            }
            Self::DuplicateTransport => f.write_str("candidate repeats a transport capability"),
            Self::DuplicateCandidateId => f.write_str("candidate set repeats a candidate id"),
            Self::InvalidGeneration => f.write_str("candidate generation must be non-zero"),
            Self::SrflxTransportMismatch => {
                f.write_str("server-reflexive candidate must advertise only QUIC or UDP_DATAGRAM")
            }
            Self::RelayTransportMismatch => {
                f.write_str("Relay candidate has an invalid direct transport capability")
            }
            Self::CandidateSetTooLarge => f.write_str("candidate set exceeds the bounded limit"),
            Self::CandidatePayloadTooLarge => {
                f.write_str("candidate payload exceeds the bounded byte limit")
            }
            Self::MalformedEncoding => f.write_str("candidate payload encoding is invalid"),
        }
    }
}

impl std::error::Error for CandidatePayloadError {}

/// Canonical identity of a candidate set. Every candidate field that can affect
/// direct probing or candidate ordering is included, so an equal revision with
/// any changed candidate metadata is rejected rather than silently refreshed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CandidateFingerprint(Vec<CandidateFingerprintEntry>);

#[derive(Debug, Clone, PartialEq, Eq)]
struct CandidateFingerprintEntry {
    candidate_id: String,
    endpoint: SocketAddr,
    kind: CandidateKind,
    transport_capabilities: Vec<CandidateTransport>,
    priority: u32,
    interface: String,
    generation: u64,
}

impl CandidateFingerprint {
    pub fn from_candidates(
        candidates: &[CandidatePayloadV2],
    ) -> Result<Self, CandidatePayloadError> {
        let mut entries = Vec::with_capacity(candidates.len());
        for candidate in candidates {
            let candidate = candidate.clone().normalized()?;
            entries.push(CandidateFingerprintEntry {
                candidate_id: candidate.candidate_id,
                endpoint: candidate.endpoint,
                kind: candidate.kind,
                transport_capabilities: candidate.transport_capabilities,
                priority: candidate.priority,
                interface: candidate.interface,
                generation: candidate.generation,
            });
        }
        entries.sort_by(|left, right| {
            left.candidate_id
                .cmp(&right.candidate_id)
                .then_with(|| left.endpoint.cmp(&right.endpoint))
                .then_with(|| {
                    candidate_kind_order(left.kind).cmp(&candidate_kind_order(right.kind))
                })
                .then_with(|| {
                    left.transport_capabilities
                        .cmp(&right.transport_capabilities)
                })
                .then_with(|| left.priority.cmp(&right.priority))
                .then_with(|| left.interface.cmp(&right.interface))
                .then_with(|| left.generation.cmp(&right.generation))
        });
        entries.dedup();
        Ok(Self(entries))
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

fn candidate_kind_order(kind: CandidateKind) -> u8 {
    match kind {
        CandidateKind::Lan => 0,
        CandidateKind::PublicIpv6 => 1,
        CandidateKind::ServerReflexive => 2,
        CandidateKind::PortMapped => 3,
        CandidateKind::Relay => 4,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedCandidateSnapshot {
    pub runtime_epoch: RuntimeEpoch,
    pub revision: u64,
    pub candidates: Vec<CandidatePayloadV2>,
    /// The server-confirmed Ready.presence_ttl_s. Zero means use the safe
    /// local fallback rather than treating the cache as immediately expired.
    pub server_presence_ttl: Option<Duration>,
}

impl ResolvedCandidateSnapshot {
    fn normalized(self) -> Result<Self, CandidatePayloadError> {
        if self.candidates.len() > MAX_CANDIDATE_PAYLOAD_ENTRIES {
            return Err(CandidatePayloadError::CandidateSetTooLarge);
        }
        let mut candidates = self
            .candidates
            .into_iter()
            .map(CandidatePayloadV2::normalized)
            .collect::<Result<Vec<_>, _>>()?;
        let mut ids = HashSet::with_capacity(candidates.len());
        if candidates
            .iter()
            .any(|candidate| !ids.insert(candidate.candidate_id.clone()))
        {
            return Err(CandidatePayloadError::DuplicateCandidateId);
        }
        let encoded = serde_json::to_vec(&candidates)
            .map_err(|_| CandidatePayloadError::CandidatePayloadTooLarge)?;
        if encoded.len() > MAX_CANDIDATE_PAYLOAD_BYTES {
            return Err(CandidatePayloadError::CandidatePayloadTooLarge);
        }
        candidates.sort_by(|left, right| {
            left.endpoint
                .cmp(&right.endpoint)
                .then_with(|| {
                    candidate_kind_order(left.kind).cmp(&candidate_kind_order(right.kind))
                })
                .then_with(|| left.candidate_id.cmp(&right.candidate_id))
        });
        Ok(Self { candidates, ..self })
    }

    fn ttl(&self) -> Duration {
        self.server_presence_ttl
            .filter(|ttl| !ttl.is_zero())
            .unwrap_or(DEFAULT_REMOTE_CANDIDATE_CACHE_TTL)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheUpdate {
    Replaced,
    Refreshed,
    IgnoredStale,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CandidateCacheError {
    InvalidSnapshot(CandidatePayloadError),
    SameRevisionDifferentFingerprint,
}

impl std::fmt::Display for CandidateCacheError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidSnapshot(error) => {
                write!(f, "invalid resolved candidate snapshot: {error}")
            }
            Self::SameRevisionDifferentFingerprint => {
                f.write_str("same discovery revision has a different candidate fingerprint")
            }
        }
    }
}

impl std::error::Error for CandidateCacheError {}

/// Remote candidates learned from an authoritative Resolve or a matching
/// ConnectivityAnswer. All age checks use `Instant`; published wall-clock timestamps are intentionally absent from this type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedCandidateCache {
    pub runtime_epoch: RuntimeEpoch,
    pub revision: u64,
    pub candidates: Vec<CandidatePayloadV2>,
    pub fingerprint: CandidateFingerprint,
    pub learned_at: Instant,
    ttl: Duration,
    retired_epochs: HashSet<RuntimeEpoch>,
    expected_epoch: Option<RuntimeEpoch>,
}

impl ResolvedCandidateCache {
    pub fn from_snapshot(
        snapshot: ResolvedCandidateSnapshot,
        learned_at: Instant,
    ) -> Result<Self, CandidateCacheError> {
        let snapshot = snapshot
            .normalized()
            .map_err(CandidateCacheError::InvalidSnapshot)?;
        let fingerprint = CandidateFingerprint::from_candidates(&snapshot.candidates)
            .map_err(CandidateCacheError::InvalidSnapshot)?;
        let ttl = snapshot.ttl();
        let runtime_epoch = snapshot.runtime_epoch;
        let revision = snapshot.revision;
        let candidates = snapshot.candidates;
        Ok(Self {
            runtime_epoch,
            revision,
            candidates,
            fingerprint,
            learned_at,
            ttl,
            retired_epochs: HashSet::new(),
            expected_epoch: None,
        })
    }

    pub fn ttl(&self) -> Duration {
        self.ttl
    }

    pub fn age_at(&self, now: Instant) -> Duration {
        now.saturating_duration_since(self.learned_at)
    }

    pub fn is_fresh_at(&self, now: Instant) -> bool {
        !self.candidates.is_empty() && self.age_at(now) <= self.ttl
    }

    pub fn stage_a_candidates_at(&self, now: Instant) -> Option<&[CandidatePayloadV2]> {
        self.is_fresh_at(now).then_some(self.candidates.as_slice())
    }

    /// Return the remote epoch announced by an invalidation hint that has not
    /// yet been replaced by a matching authoritative snapshot. Callers that
    /// own an already-established path can use this fence to retire the old
    /// transport before attempting a pre-Resolve reuse.
    pub fn pending_remote_epoch(&self) -> Option<RuntimeEpoch> {
        self.expected_epoch
    }

    /// Applies an authoritative snapshot or matching live answer.
    pub fn apply(
        &mut self,
        snapshot: ResolvedCandidateSnapshot,
        learned_at: Instant,
    ) -> Result<CacheUpdate, CandidateCacheError> {
        let snapshot = snapshot
            .normalized()
            .map_err(CandidateCacheError::InvalidSnapshot)?;
        let fingerprint = CandidateFingerprint::from_candidates(&snapshot.candidates)
            .map_err(CandidateCacheError::InvalidSnapshot)?;

        if self.retired_epochs.contains(&snapshot.runtime_epoch) {
            return Ok(CacheUpdate::IgnoredStale);
        }

        if let Some(expected_epoch) = self.expected_epoch {
            if snapshot.runtime_epoch == expected_epoch {
                self.expected_epoch = None;
            } else {
                self.retire_epoch(expected_epoch);
                self.expected_epoch = None;
            }
        }

        if snapshot.runtime_epoch == self.runtime_epoch {
            match snapshot.revision.cmp(&self.revision) {
                Ordering::Less => return Ok(CacheUpdate::IgnoredStale),
                Ordering::Equal if fingerprint != self.fingerprint => {
                    return Err(CandidateCacheError::SameRevisionDifferentFingerprint)
                }
                Ordering::Equal => {
                    self.ttl = snapshot.ttl();
                    // A caller may deliver an already-queued snapshot after
                    // a newer one.  Keep the native monotonic learning point
                    // from moving backwards even when the revision/fingerprint
                    // is otherwise a harmless refresh.
                    self.learned_at = self.learned_at.max(learned_at);
                    return Ok(CacheUpdate::Refreshed);
                }
                Ordering::Greater => {}
            }
        }

        let ttl = snapshot.ttl();
        self.retire_epoch(self.runtime_epoch);
        self.runtime_epoch = snapshot.runtime_epoch;
        self.revision = snapshot.revision;
        self.candidates = snapshot.candidates;
        self.fingerprint = fingerprint;
        self.learned_at = self.learned_at.max(learned_at);
        self.ttl = ttl;
        Ok(CacheUpdate::Replaced)
    }

    /// Immediately makes the old remote snapshot unavailable for Stage A.
    /// The next snapshot from the new epoch will replace the retained metadata.
    pub fn invalidate_for_remote_epoch(
        &mut self,
        remote_epoch: RuntimeEpoch,
        now: Instant,
    ) -> bool {
        if remote_epoch == self.runtime_epoch {
            return false;
        }
        self.retire_epoch(self.runtime_epoch);
        self.expected_epoch = Some(remote_epoch);
        self.candidates.clear();
        self.fingerprint = CandidateFingerprint(Vec::new());
        self.learned_at = now
            .checked_sub(self.ttl + Duration::from_nanos(1))
            .unwrap_or(now);
        true
    }

    fn retire_epoch(&mut self, epoch: RuntimeEpoch) {
        if self.retired_epochs.len() >= MAX_RETIRED_EPOCHS && !self.retired_epochs.contains(&epoch)
        {
            if let Some(evicted) = self.retired_epochs.iter().next().copied() {
                self.retired_epochs.remove(&evicted);
            }
        }
        self.retired_epochs.insert(epoch);
    }
}

#[cfg(test)]
#[path = "tests/candidate_v2.rs"]
mod tests;
