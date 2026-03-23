use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::LazyLock;
use std::time::Duration;

use tokio::time::Instant;

pub fn create_deadline(duration: Duration) -> Instant {
    Instant::now() + duration
}

static IS_RUNNING_ON_LAMBDA: LazyLock<AtomicBool> =
    LazyLock::new(|| AtomicBool::new(std::env::var("AWS_LAMBDA_FUNCTION_NAME").is_ok()));

pub fn is_running_on_lambda() -> bool {
    IS_RUNNING_ON_LAMBDA.load(Ordering::Relaxed)
}

static IS_RUNNING_ON_ECS: LazyLock<AtomicBool> = LazyLock::new(|| {
    AtomicBool::new(std::env::var("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI").is_ok())
});

pub fn is_running_on_ecs() -> bool {
    IS_RUNNING_ON_ECS.load(Ordering::Relaxed)
}

/// Minimum system memory in GiB required to enable readahead cache.
/// Targets modern 2xlarge instances (M*.2xlarge with 32 GiB) or larger.
pub const MIN_MEMORY_FOR_READAHEAD_GIB: u64 = 30;

/// Returns true if system has enough memory for readahead cache.
/// Returns false on Lambda/ECS since memory detection shows host, not container limits.
pub fn has_sufficient_memory_for_readahead_cache() -> bool {
    if is_running_on_lambda() || is_running_on_ecs() {
        return false;
    }
    let total_memory = sysinfo::System::new_all().total_memory();
    if total_memory == 0 {
        log::warn!("Unable to determine system memory, disabling readahead cache");
    }
    total_memory >= MIN_MEMORY_FOR_READAHEAD_GIB * 1024 * 1024 * 1024
}

#[cfg(test)]
pub fn reset_mock_lambda() {
    IS_RUNNING_ON_LAMBDA.store(
        std::env::var("AWS_LAMBDA_FUNCTION_NAME").is_ok(),
        Ordering::Relaxed,
    );
}
