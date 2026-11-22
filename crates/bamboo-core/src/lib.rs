//! Links every Bamboo component crate into one static library for the app.
//!
//! Each component exports its own UniFFI interface; the `pub use` lines keep
//! their symbols in the final archive.

pub use bamboo_agent;
pub use bamboo_import;
pub use bamboo_shields;
pub use bamboo_store;

uniffi::setup_scaffolding!();

/// Version of the Rust core, shown in About and sent to MCP clients.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
