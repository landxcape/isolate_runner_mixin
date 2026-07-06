# Changelog

## 0.4.1 - Documentation & Formatting Patch

* Applied `dart format` to all source files (fixes pub.dev static-analysis
  score for the 0.4.0 release).
* Expanded README: added error-handling section documenting all six exception
  types, noted worker sequential-processing behaviour, documented
  `SpawnWorkerOptions.startupTimeout` and the per-request `timeout` parameter,
  added `isWorkerRunning` to the lifecycle summary, and fixed minor example
  issues (missing handler definition in Flutter lifecycle snippet, method name
  shadowing `dart:core double`).

## 0.4.0 - Static API & Bug Fixes

**New**

* Added `IsolateRunnerMixin.run<T>()` — static counterpart to `runInIsolate`, usable
  without a mixin instance.
* Added `IsolateRunnerMixin.runWithArg<A, R>()` — static counterpart to
  `runInIsolateWithArg`.
* `runInIsolate` and `runInIsolateWithArg` now delegate to the static methods,
  making all execution logic share a single code path.

**Bug Fixes**

* Fixed TOCTOU race in `spawnWorker`: configuration fields are now written only
  after any in-flight startup completes, preventing handler corruption on concurrent
  calls with different handlers.
* Fixed recursive `_ensureWorkerSpawned` in the disposing branch: replaced the
  unbounded tail-recursive call with an explicit `while` loop.
* Fixed teardown race in `_handleWorkerTermination`: all port and subscription
  references are now nulled synchronously before the state is updated to `stopped`,
  preventing premature re-spawn attempts during async cleanup.
* Fixed `_isAllowedPayload` incorrectly returning `true` for self-referencing
  `List` and `Map` structures — such cycles are not sendable across isolate
  boundaries and now correctly return `false`.

**Improvements**

* Removed dead `maxPendingRequests` guard in `spawnWorker` (superseded by the
  `assert` in `SpawnWorkerOptions`).
* Added `assert(_spawnFuture != null)` guard to catch invariant violations in
  the `starting` state during debug builds.
* Added clarifying comment on `static _workerLeakFinalizer` explaining per-instance
  detach token design.
* Removed `prefer_relative_imports` lint rule (conflicts with pub.dev package
  best practices).
* Added `topics` to `pubspec.yaml` for better pub.dev discoverability.

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
