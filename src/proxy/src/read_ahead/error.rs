use thiserror::Error as ThisError;

// TODO [2025-06-19 admsam] Add more error specific errors
#[derive(Debug, ThisError)]
#[error("ReadAheadCache error: {message}")]
pub struct ReadAheadCacheError {
    pub message: String,
}
