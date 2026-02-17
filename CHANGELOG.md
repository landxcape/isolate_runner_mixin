# Changelog

## 0.3.0 - Spawn Worker Lifecycle

* Added persistent spawned-worker APIs: `spawnWorker`, `requestWorker`,
  `disposeWorker`, and `isWorkerRunning`.
* Added `SpawnWorkerOptions` with `maxPendingRequests` and startup timeout.
* Added sequential worker request protocol with queue overflow protection.
* Improved convenience behavior: calling `spawnWorker` with updated handler or
  options now restarts the active worker automatically.
* Added package exception types for initialization, payload, queue, remote
  worker failures, unexpected termination, and disposal cases.
* Added debug leak warning when a spawned worker is not disposed.
* Added comprehensive tests for worker lifecycle, idempotent spawn, timeout,
  queue behavior, error propagation, and auto-respawn.

## 0.2.0 - Feature Update

* Added `IsolateRunMode` with `auto`, `alwaysIsolate`, and `currentIsolate`.
* Added optional `timeout` to `runInIsolate`.
* Added `runInIsolateWithArg` convenience API.
* Added comprehensive tests for mode behavior, async/sync execution,
  error propagation, and timeout handling.

## 0.1.1 - Patch

* Refactored

## 0.1.0 - Initial Release

* Introduced `IsolateRunnerMixin` for running functions in background isolates.
* Handles `RootIsolateToken` and `BackgroundIsolateBinaryMessenger` initialization for Flutter plugin compatibility.
* Provides graceful fallback for non-Flutter environments
