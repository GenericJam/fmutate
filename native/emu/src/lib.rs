//! The emulator engine around fm1-emu (docs/engine_protocol.md "The emulator engine"): `engine::run` behind
//! either host, the `fm1emu` executable (main.rs, Android and the tests) or a thread of the iOS app (`ffi`, a
//! static library linked into it).

pub mod edges;
pub mod engine;
pub mod ffi;
pub mod machine;
pub mod sys;
