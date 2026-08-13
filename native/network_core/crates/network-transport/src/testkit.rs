//! Deterministic write-pressure test seam.
//!
//! Compiled only with the `testkit` feature. [`WriterGate`] parks a transport
//! writer's `send` until a test releases it, so route tests can prove that an
//! in-flight transport write does not stall the read half and that route
//! cancellation preempts a blocked write. Production builds never include this
//! module, and UDP datagram semantics are unchanged.

use crate::{TransportError, TransportKind, TransportReader, TransportWriter, TransportWriterKind};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use tokio::sync::Notify;

/// A deterministic gate placed in front of a transport writer's `send`.
///
/// The first `send` that passes through the gate signals entry (observable via
/// [`entered`](WriterGate::entered)) and then parks until
/// [`release`](WriterGate::release) is called. Later sends pass through without
/// parking, which keeps a route usable after the pressure scenario clears.
#[derive(Clone, Default)]
pub struct WriterGate {
    state: Arc<GateState>,
}

#[derive(Default)]
struct GateState {
    entered: Notify,
    release: Notify,
    parked: AtomicBool,
}

impl WriterGate {
    /// Creates an unreleased gate.
    pub fn new() -> Self {
        Self::default()
    }

    /// Awaits until a gated writer has entered `send` and is parked in-flight.
    ///
    /// The notification is stored if the writer entered before this future is
    /// polled, so there is no lost-wakeup window.
    pub async fn entered(&self) {
        self.state.entered.notified().await;
    }

    /// Releases a parked gated `send`; its write then reaches the socket.
    pub fn release(&self) {
        self.state.release.notify_one();
    }

    /// Signals that a `send` entered the gate and parks the first caller until
    /// the test releases it. Called by [`GatedWriter`].
    pub(crate) async fn park_and_wait(&self) {
        let parks = !self.state.parked.swap(true, Ordering::AcqRel);
        self.state.entered.notify_one();
        if parks {
            self.state.release.notified().await;
        }
    }
}

/// A transport writer that parks its first `send` on a [`WriterGate`] before
/// forwarding it to the underlying transport half. The inner kind is boxed to
/// break the otherwise-infinite `TransportWriterKind -> GatedWriter` recursion.
pub(crate) struct GatedWriter {
    pub(crate) inner: Box<TransportWriterKind>,
    pub(crate) gate: WriterGate,
}

impl GatedWriter {
    pub(crate) async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        self.gate.park_and_wait().await;
        match &mut *self.inner {
            TransportWriterKind::Tcp(writer) => writer.send_frame(payload).await,
            TransportWriterKind::Udp(writer) => writer.send_datagram(payload).await,
            TransportWriterKind::WebSocket(writer) => {
                crate::websocket::send_binary(writer, payload).await
            }
            TransportWriterKind::Gated(_) => unreachable!("nested gated writer"),
        }
    }

    pub(crate) async fn close(&mut self) -> Result<(), TransportError> {
        match &mut *self.inner {
            TransportWriterKind::Tcp(writer) => writer.close().await,
            TransportWriterKind::Udp(writer) => writer.close().await,
            TransportWriterKind::WebSocket(writer) => crate::websocket::close(writer).await,
            TransportWriterKind::Gated(_) => unreachable!("nested gated writer"),
        }
    }
}

/// A transport that keeps a real reader half and a gated writer half.
pub struct GatedTransport {
    pub(crate) kind: TransportKind,
    pub(crate) reader: TransportReader,
    pub(crate) writer: GatedWriter,
}

impl GatedTransport {
    pub(crate) fn into_split(self) -> (TransportReader, TransportWriter) {
        (
            self.reader,
            TransportWriter {
                inner: TransportWriterKind::Gated(self.writer),
            },
        )
    }

    pub(crate) fn kind(&self) -> TransportKind {
        self.kind
    }

    pub(crate) async fn send(&mut self, payload: &[u8]) -> Result<usize, TransportError> {
        self.writer.send(payload).await
    }

    pub(crate) async fn recv(&mut self) -> Result<Vec<u8>, TransportError> {
        self.reader.recv().await
    }

    pub(crate) async fn close(&mut self) -> Result<(), TransportError> {
        self.writer.close().await
    }
}
