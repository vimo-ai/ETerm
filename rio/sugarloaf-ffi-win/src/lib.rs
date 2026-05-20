// FFI functions dereference raw pointers by design - this is expected for C-compatible APIs
#![allow(clippy::not_unsafe_ptr_arg_deref)]
// Allow dead code on non-Windows platforms (entire crate is Windows-only)
#![allow(dead_code)]
// Allow unused imports on non-Windows (cfg-gated modules)
#![allow(unused_imports)]

pub mod ffi;
pub use ffi::*;
