//! Runtime lifecycle, transfer contracts, and reservation data-plane tests.
//!
//! The integration boundary is kept in focused source chunks so every
//! hand-written test unit remains reviewable without changing the shared
//! private-state test namespace.

include!("runtime_integration/part_01.rs");
include!("runtime_integration/part_02.rs");
include!("runtime_integration/part_03.rs");
include!("runtime_integration/part_04.rs");
include!("runtime_integration/part_05.rs");
include!("runtime_integration/part_06.rs");
include!("runtime_integration/part_07.rs");
include!("runtime_integration/part_08.rs");
include!("runtime_integration/part_09.rs");
include!("runtime_integration/part_10.rs");
include!("runtime_integration/part_11.rs");
include!("runtime_integration/part_12.rs");
include!("runtime_integration/part_13.rs");
