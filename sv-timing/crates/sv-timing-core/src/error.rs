// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Error types for sv-timing-core.

use std::path::PathBuf;

use thiserror::Error;

/// Result alias for core operations.
pub type CoreResult<T> = Result<T, CoreError>;

/// Errors produced while parsing or locating sources.
#[derive(Debug, Error)]
pub enum CoreError {
    /// Filesystem I/O failure.
    #[error("io error for {path}: {source}")]
    Io {
        /// Path related to the failure.
        path: PathBuf,
        /// Underlying I/O error.
        #[source]
        source: std::io::Error,
    },

    /// sv-parser returned an error.
    #[error("parse error in {path}: {message}")]
    Parse {
        /// Source path.
        path: PathBuf,
        /// Human-readable message.
        message: String,
    },

    /// Invalid CLI / API options.
    #[error("invalid options: {0}")]
    InvalidOptions(String),
}
