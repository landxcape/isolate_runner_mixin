import 'dart:async';

import 'package:isolate_runner_mixin/src/isolate_models.dart';

class _PendingWebRequest {
  final Completer<Object?> completer;
  final Timer? timeoutTimer;

  const _PendingWebRequest({
    required this.completer,
    required this.timeoutTimer,
  });
}

/// A mixin providing background execution and persistent worker patterns.
///
/// On Web and WebAssembly (WASM) targets, where native OS isolates are unavailable,
/// this mixin seamlessly executes computations on the async event loop with
/// microtask-yielding and identical payload and exception semantics.
mixin IsolateRunnerMixin {
  WorkerState _workerState = WorkerState.stopped;
  IsolateWorkerHandler? _registeredWorkerHandler;
  SpawnWorkerOptions _spawnWorkerOptions = const SpawnWorkerOptions();
  final Map<int, _PendingWebRequest> _pendingRequests =
      <int, _PendingWebRequest>{};
  int _nextRequestId = 0;

  /// Returns true when a worker is currently active and ready for requests.
  bool get isWorkerRunning => _workerState == WorkerState.running;

  /// Runs the given [fn] on the asynchronous event loop with cooperative yielding.
  ///
  /// On Web and WebAssembly platforms, this yields to the event loop before
  /// executing [fn] to prevent blocking the frame render pipeline.
  Future<T> runInIsolate<T>(
    FutureOr<T> Function() fn, {
    IsolateRunMode mode = IsolateRunMode.auto,
    Duration? timeout,
  }) async {
    final executionFuture = _runWebTask(fn);
    if (timeout == null) {
      return await executionFuture;
    }
    return await executionFuture.timeout(timeout);
  }

  Future<T> _runWebTask<T>(FutureOr<T> Function() fn) async {
    // Yield to the browser event loop so pending paint/compositing ticks complete
    await Future<void>.delayed(Duration.zero);
    return await fn();
  }

  /// Convenience wrapper that passes a single argument to [fn].
  Future<R> runInIsolateWithArg<A, R>(
    A argument,
    FutureOr<R> Function(A argument) fn, {
    IsolateRunMode mode = IsolateRunMode.auto,
    Duration? timeout,
  }) async {
    return await runInIsolate(() => fn(argument), mode: mode, timeout: timeout);
  }

  /// Registers a persistent worker handler.
  Future<void> spawnWorker({
    required IsolateWorkerHandler handler,
    SpawnWorkerOptions options = const SpawnWorkerOptions(),
  }) async {
    _registeredWorkerHandler = handler;
    _spawnWorkerOptions = options;
    _workerState = WorkerState.running;
  }

  /// Sends a request to the persistent worker.
  Future<R> requestWorker<R>({
    required String command,
    Object? payload,
    Duration? timeout,
  }) async {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    if (!isAllowedPayload(payload)) {
      throw IsolateWorkerPayloadException(
        'Payload for command "$command" is not sendable by this package contract.',
      );
    }

    if (_workerState == WorkerState.stopped) {
      if (_registeredWorkerHandler != null) {
        await spawnWorker(
          handler: _registeredWorkerHandler!,
          options: _spawnWorkerOptions,
        );
      } else {
        throw const IsolateWorkerNotInitializedException(
          'Worker has not been initialized. Call spawnWorker() before requestWorker().',
        );
      }
    }

    if (_pendingRequests.length >= _spawnWorkerOptions.maxPendingRequests) {
      throw IsolateWorkerQueueOverflowException(
        'Pending request count (${_pendingRequests.length}) reached the max '
        'limit of ${_spawnWorkerOptions.maxPendingRequests}.',
      );
    }

    final requestId = _nextRequestId++;
    final completer = Completer<Object?>();
    Timer? timeoutTimer;

    if (timeout != null) {
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          _pendingRequests.remove(requestId);
          completer.completeError(
            TimeoutException(
              'Worker request "$command" timed out after $timeout.',
              timeout,
            ),
          );
        }
      });
    }

    _pendingRequests[requestId] = _PendingWebRequest(
      completer: completer,
      timeoutTimer: timeoutTimer,
    );

    // Dispatch asynchronously
    scheduleMicrotask(() async {
      try {
        final handler = _registeredWorkerHandler;
        if (handler == null) {
          throw const IsolateWorkerNotInitializedException(
            'Worker handler not found.',
          );
        }

        final result = await handler(command, payload);
        if (!isAllowedPayload(result)) {
          throw IsolateWorkerPayloadException(
            'Worker result for command "$command" is not sendable by this package contract.',
          );
        }

        if (!completer.isCompleted) {
          timeoutTimer?.cancel();
          _pendingRequests.remove(requestId);
          completer.complete(result);
        }
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          timeoutTimer?.cancel();
          _pendingRequests.remove(requestId);
          completer.completeError(
            IsolateWorkerRemoteException(
              command: command,
              remoteError: error.toString(),
              remoteStackTrace: stackTrace.toString(),
            ),
            stackTrace,
          );
        }
      }
    });

    final response = await completer.future;
    return response as R;
  }

  /// Disposes the persistent worker and cancels any pending requests.
  Future<void> disposeWorker() async {
    _workerState = WorkerState.disposing;
    for (final request in _pendingRequests.values) {
      request.timeoutTimer?.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          const IsolateWorkerDisposedException(
            'Worker disposed while request was in-flight.',
          ),
        );
      }
    }
    _pendingRequests.clear();
    _workerState = WorkerState.stopped;
  }
}
