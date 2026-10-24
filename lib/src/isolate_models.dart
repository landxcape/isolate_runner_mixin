import 'dart:async';

/// Controls where [IsolateRunnerMixin.runInIsolate] executes a task.
enum IsolateRunMode {
  /// Use a background isolate when a [RootIsolateToken] is available;
  /// otherwise, run on the current isolate.
  auto,

  /// Always execute on a background isolate.
  alwaysIsolate,

  /// Always execute on the current isolate.
  currentIsolate,
}

/// Worker request handler used by [IsolateRunnerMixin.spawnWorker].
///
/// The provided function should be a top-level or static function. If it
/// captures non-sendable values, isolate spawn can fail.
typedef IsolateWorkerHandler =
    FutureOr<Object?> Function(String command, Object? payload);

/// Options for spawned worker behavior.
class SpawnWorkerOptions {
  /// Maximum number of pending requests waiting for completion.
  ///
  /// Must be greater than zero.
  final int maxPendingRequests;

  /// Optional timeout for worker startup.
  final Duration? startupTimeout;

  /// Creates configuration options for worker behavior.
  const SpawnWorkerOptions({
    this.maxPendingRequests = 1000,
    this.startupTimeout,
  }) : assert(maxPendingRequests > 0, 'maxPendingRequests must be > 0');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is SpawnWorkerOptions &&
        other.maxPendingRequests == maxPendingRequests &&
        other.startupTimeout == startupTimeout;
  }

  @override
  int get hashCode => Object.hash(maxPendingRequests, startupTimeout);
}

/// Base exception type for spawned worker operations.
class IsolateWorkerException implements Exception {
  /// Informative error message.
  final String message;

  /// Creates a new [IsolateWorkerException] with the given [message].
  const IsolateWorkerException(this.message);

  @override
  String toString() => 'IsolateWorkerException: $message';
}

/// Thrown when a request is attempted before a worker handler is registered.
class IsolateWorkerNotInitializedException extends IsolateWorkerException {
  /// Creates an exception when the worker handler has not been registered.
  const IsolateWorkerNotInitializedException(super.message);
}

/// Thrown when pending request count exceeds [SpawnWorkerOptions.maxPendingRequests].
class IsolateWorkerQueueOverflowException extends IsolateWorkerException {
  /// Creates an exception when the request queue overflows.
  const IsolateWorkerQueueOverflowException(super.message);
}

/// Thrown when request payload/result does not satisfy the package payload contract.
class IsolateWorkerPayloadException extends IsolateWorkerException {
  /// Creates an exception when payload serialization constraints are violated.
  const IsolateWorkerPayloadException(super.message);
}

/// Thrown when the worker isolate is disposed while requests are pending.
class IsolateWorkerDisposedException extends IsolateWorkerException {
  /// Creates an exception when pending operations are canceled during disposal.
  const IsolateWorkerDisposedException(super.message);
}

/// Thrown when the worker isolate terminates unexpectedly.
class IsolateWorkerTerminatedException extends IsolateWorkerException {
  /// Optional stack trace captured from the worker isolate prior to termination.
  final String? workerStackTrace;

  /// Creates an exception when a worker isolate exits unexpectedly.
  const IsolateWorkerTerminatedException(
    super.message, {
    this.workerStackTrace,
  });
}

/// Thrown when a worker handler request fails in the worker isolate.
class IsolateWorkerRemoteException extends IsolateWorkerException {
  /// Command name passed to [IsolateRunnerMixin.requestWorker].
  final String command;

  /// Text representation of the error thrown in the worker isolate.
  final String remoteError;

  /// String form of the stack trace from the worker isolate.
  final String? remoteStackTrace;

  /// Creates an exception containing the failed command and remote stack trace.
  const IsolateWorkerRemoteException({
    required this.command,
    required this.remoteError,
    this.remoteStackTrace,
  }) : super('Worker command "$command" failed: $remoteError');
}

/// Internal state of a worker runner.
enum WorkerState { stopped, starting, running, disposing }

/// Validates whether a value is sendable across isolates or meets payload contracts.
bool isAllowedPayload(Object? value, [Set<Object>? seen]) {
  if (value == null || value is bool || value is num || value is String) {
    return true;
  }

  // Handle native isolate primitives if available without hard dependency
  final runtimeTypeName = value.runtimeType.toString();
  if (runtimeTypeName == 'SendPort' ||
      runtimeTypeName == 'TransferableTypedData' ||
      runtimeTypeName == '_SendPort') {
    return true;
  }

  final visited = seen ?? <Object>{};
  if (value is List) {
    if (visited.contains(value)) {
      return false; // Cycle detected
    }
    visited.add(value);
    for (final Object? item in value.cast<Object?>()) {
      if (!isAllowedPayload(item, visited)) {
        return false;
      }
    }
    return true;
  }

  if (value is Map) {
    if (visited.contains(value)) {
      return false; // Cycle detected
    }
    visited.add(value);
    for (final MapEntry<Object?, Object?> entry
        in value.cast<Object?, Object?>().entries) {
      if (!isAllowedPayload(entry.key, visited) ||
          !isAllowedPayload(entry.value, visited)) {
        return false;
      }
    }
    return true;
  }

  return false;
}
