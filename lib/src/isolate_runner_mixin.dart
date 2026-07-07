import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  final String message;

  const IsolateWorkerException(this.message);

  @override
  String toString() => 'IsolateWorkerException: $message';
}

/// Thrown when a request is attempted before a worker handler is registered.
class IsolateWorkerNotInitializedException extends IsolateWorkerException {
  const IsolateWorkerNotInitializedException(super.message);
}

/// Thrown when pending request count exceeds [SpawnWorkerOptions.maxPendingRequests].
class IsolateWorkerQueueOverflowException extends IsolateWorkerException {
  const IsolateWorkerQueueOverflowException(super.message);
}

/// Thrown when request payload/result does not satisfy the package payload contract.
class IsolateWorkerPayloadException extends IsolateWorkerException {
  const IsolateWorkerPayloadException(super.message);
}

/// Thrown when the worker isolate is disposed while requests are pending.
class IsolateWorkerDisposedException extends IsolateWorkerException {
  const IsolateWorkerDisposedException(super.message);
}

/// Thrown when the worker isolate terminates unexpectedly.
class IsolateWorkerTerminatedException extends IsolateWorkerException {
  final String? workerStackTrace;

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

  const IsolateWorkerRemoteException({
    required this.command,
    required this.remoteError,
    this.remoteStackTrace,
  }) : super('Worker command "$command" failed: $remoteError');
}

enum _WorkerState { stopped, starting, running, disposing }

class _PendingWorkerRequest {
  final String command;
  final Completer<Object?> completer;
  final Timer? timeoutTimer;

  const _PendingWorkerRequest({
    required this.command,
    required this.completer,
    required this.timeoutTimer,
  });
}

class _WorkerLeakTrace {
  final String ownerType;
  final String spawnStackTrace;

  const _WorkerLeakTrace({
    required this.ownerType,
    required this.spawnStackTrace,
  });
}

const String _kTypeKey = 'type';
const String _kReadyType = 'ready';
const String _kRequestType = 'request';
const String _kResponseType = 'response';
const String _kErrorType = 'error';
const String _kDisposeType = 'dispose';
const String _kMainSendPortKey = 'mainSendPort';
const String _kWorkerSendPortKey = 'workerSendPort';
const String _kTokenKey = 'token';
const String _kHandlerKey = 'handler';
const String _kRequestIdKey = 'requestId';
const String _kCommandKey = 'command';
const String _kPayloadKey = 'payload';
const String _kResultKey = 'result';
const String _kErrorMessageKey = 'error';
const String _kStackTraceKey = 'stackTrace';
const String _kExitSignal = 'worker-exit';

// ------------------- Isolate Communication Models (Top-level) --------------------

/// The generic data class to hold the token and the function to run.
/// This is passed to the actual isolate entry point.
///
/// This class is private to the package as it's an internal implementation detail.
class _IsolateTask<T> {
  final RootIsolateToken? token;
  final FutureOr<T> Function() task;

  _IsolateTask(this.token, this.task);
}

// ------------------- Isolate Entry Point (Top-level Function) --------------------

/// This is the actual top-level function that the isolate will run.
/// It receives the [_IsolateTask] and executes the contained function.
///
/// This function must be top-level or static to be used as an isolate entry point.
/// It's private to the package as it's an internal implementation detail.
Future<T> _isolateEntryPoint<T>(_IsolateTask<T> task) async {
  // Initialize messenger in the worker isolate so plugin calls can work.
  if (task.token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(task.token!);
  }

  return await task.task();
}

@pragma('vm:entry-point')
Future<void> _workerIsolateEntryPoint(Object? rawMessage) async {
  final message = rawMessage as Map<Object?, Object?>;
  final mainSendPort = message[_kMainSendPortKey] as SendPort;
  final token = message[_kTokenKey] as RootIsolateToken?;
  final handler = message[_kHandlerKey] as IsolateWorkerHandler;

  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }

  final workerPort = ReceivePort();
  mainSendPort.send(<String, Object?>{
    _kTypeKey: _kReadyType,
    _kWorkerSendPortKey: workerPort.sendPort,
  });

  await for (final Object? incoming in workerPort) {
    if (incoming is! Map<Object?, Object?>) {
      continue;
    }

    final type = incoming[_kTypeKey] as String?;
    if (type == _kDisposeType) {
      workerPort.close();
      break;
    }

    if (type != _kRequestType) {
      continue;
    }

    final requestId = incoming[_kRequestIdKey] as int;
    final command = incoming[_kCommandKey] as String;
    final payload = incoming[_kPayloadKey];

    try {
      final result = await handler(command, payload);
      if (!_isAllowedPayload(result)) {
        throw IsolateWorkerPayloadException(
          'Worker result for command "$command" is not sendable by this package contract.',
        );
      }

      mainSendPort.send(<String, Object?>{
        _kTypeKey: _kResponseType,
        _kRequestIdKey: requestId,
        _kResultKey: result,
      });
    } catch (error, stackTrace) {
      mainSendPort.send(<String, Object?>{
        _kTypeKey: _kErrorType,
        _kRequestIdKey: requestId,
        _kErrorMessageKey: error.toString(),
        _kStackTraceKey: stackTrace.toString(),
      });
    }
  }
}

bool _isAllowedPayload(Object? value, [Set<Object>? seen]) {
  if (value == null ||
      value is bool ||
      value is num ||
      value is String ||
      value is SendPort ||
      value is TransferableTypedData) {
    return true;
  }

  final visited = seen ?? <Object>{};
  if (value is List) {
    if (visited.contains(value)) {
      return false; // Cycle detected; self-referencing structures are not sendable.
    }
    visited.add(value);
    for (final Object? item in value.cast<Object?>()) {
      if (!_isAllowedPayload(item, visited)) {
        return false;
      }
    }
    return true;
  }

  if (value is Map) {
    if (visited.contains(value)) {
      return false; // Cycle detected; self-referencing structures are not sendable.
    }
    visited.add(value);
    for (final MapEntry<Object?, Object?> entry
        in value.cast<Object?, Object?>().entries) {
      if (!_isAllowedPayload(entry.key, visited) ||
          !_isAllowedPayload(entry.value, visited)) {
        return false;
      }
    }
    return true;
  }

  return false;
}

// ------------------- The IsolateRunnerMixin --------------------

/// A mixin to provide a convenient `runInIsolate` method to any class.
///
/// This mixin simplifies running CPU-intensive tasks, especially those
/// that involve Flutter plugins, in a background isolate to prevent
/// blocking the UI thread.
///
/// Example Usage:
/// ```dart
/// class MyService with IsolateRunnerMixin {
///   Future<String> doHeavyWork(String input) async {
///     return await runInIsolate(() => _myHeavyComputation(input));
///   }
///
///   // This must be a top-level function or static method.
///   static Future<String> _myHeavyComputation(String input) async {
///     // Simulate heavy computation or plugin usage
///     await Future.delayed(Duration(seconds: 2));
///     return "Processed: $input";
///   }
/// }
/// ```
mixin IsolateRunnerMixin {
  // Static so the Finalizer outlives any single instance. Each instance uses
  // its own detach token (_workerLeakDetachToken) for independent lifecycle.
  static final Finalizer<_WorkerLeakTrace>
  _workerLeakFinalizer = Finalizer<_WorkerLeakTrace>((trace) {
    assert(() {
      debugPrint(
        '[isolate_runner_mixin] Spawned worker leaked for ${trace.ownerType}. '
        'Call disposeWorker() to avoid isolate/port leaks.\n'
        'Worker was spawned at:\n${trace.spawnStackTrace}',
      );
      return true;
    }());
  });

  _WorkerState _workerState = _WorkerState.stopped;
  Future<void>? _spawnFuture;
  Future<void>? _disposeFuture;
  Completer<void>? _startupCompleter;

  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _workerMessagePort;
  ReceivePort? _workerErrorPort;
  ReceivePort? _workerExitPort;
  StreamSubscription<Object?>? _workerMessageSubscription;
  StreamSubscription<Object?>? _workerErrorSubscription;
  StreamSubscription<Object?>? _workerExitSubscription;

  final Map<int, _PendingWorkerRequest> _pendingRequests =
      <int, _PendingWorkerRequest>{};
  int _nextRequestId = 0;

  IsolateWorkerHandler? _registeredWorkerHandler;
  SpawnWorkerOptions _spawnWorkerOptions = const SpawnWorkerOptions();
  IsolateWorkerHandler? _activeWorkerHandler;
  SpawnWorkerOptions? _activeSpawnWorkerOptions;
  final Object _workerLeakDetachToken = Object();

  /// Returns true when a spawned worker isolate is currently alive.
  bool get isWorkerRunning => _workerState == _WorkerState.running;

  /// Runs the given [fn] in a background isolate.
  ///
  /// This method handles the boilerplate of spawning an isolate,
  /// initializing the `BackgroundIsolateBinaryMessenger` (if a Flutter
  /// binding is available), executing the provided function [fn], and
  /// returning its result.
  ///
  /// The [fn] should encapsulate all the CPU-intensive or plugin-dependent
  /// work. The callback itself is passed and executed in the target isolate.
  /// If expensive work is done before creating [fn], that work still runs on
  /// the current isolate.
  ///
  /// Execution behavior can be controlled with [mode].
  ///
  /// If [timeout] is provided, a [TimeoutException] is thrown when execution
  /// does not complete before the given duration.
  ///
  /// Throws any errors that occur during the execution of [fn] or isolate setup.
  Future<T> runInIsolate<T>(
    FutureOr<T> Function() fn, {
    IsolateRunMode mode = IsolateRunMode.auto,
    Duration? timeout,
  }) async {
    final executionFuture = switch (mode) {
      IsolateRunMode.currentIsolate => Future<T>.sync(fn),
      IsolateRunMode.auto => _runInAutoMode(fn),
      IsolateRunMode.alwaysIsolate => _runInBackgroundIsolate(
        fn,
        token: RootIsolateToken.instance,
      ),
    };

    if (timeout == null) {
      return await executionFuture;
    }

    return await executionFuture.timeout(timeout);
  }

  /// Convenience wrapper that passes a single argument to [fn].
  ///
  /// This is equivalent to calling `runInIsolate(() => fn(argument))`.
  Future<R> runInIsolateWithArg<A, R>(
    A argument,
    FutureOr<R> Function(A argument) fn, {
    IsolateRunMode mode = IsolateRunMode.auto,
    Duration? timeout,
  }) async {
    return await runInIsolate(() => fn(argument), mode: mode, timeout: timeout);
  }

  /// Spawns a persistent worker isolate.
  ///
  /// The worker is idempotent: repeated calls while running are no-ops.
  /// If a spawn is already in progress, callers await the same startup future.
  Future<void> spawnWorker({
    required IsolateWorkerHandler handler,
    SpawnWorkerOptions options = const SpawnWorkerOptions(),
  }) async {
    // Wait for any in-flight startup before mutating configuration fields to
    // avoid a TOCTOU race when concurrent calls supply different handlers.
    if (_workerState == _WorkerState.starting) {
      await (_spawnFuture ?? Future<void>.value());
    }

    _registeredWorkerHandler = handler;
    _spawnWorkerOptions = options;

    // If configuration changed, restart so the running worker matches it.
    if (_workerState == _WorkerState.running &&
        !_isCurrentWorkerConfiguration(handler, options)) {
      await disposeWorker();
    }

    await _ensureWorkerSpawned(handler: handler, options: options);
  }

  /// Sends a request to the spawned worker isolate.
  ///
  /// If the worker is not running and a handler was previously registered
  /// through [spawnWorker], the worker is auto-spawned.
  Future<R> requestWorker<R>({
    required String command,
    Object? payload,
    Duration? timeout,
  }) async {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    if (!_isAllowedPayload(payload)) {
      throw IsolateWorkerPayloadException(
        'Payload for command "$command" is not sendable by this package contract.',
      );
    }

    await _ensureWorkerReadyForRequest();

    if (_workerSendPort == null || _workerState != _WorkerState.running) {
      throw const IsolateWorkerTerminatedException(
        'Worker is not running while processing request.',
      );
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
        final pending = _pendingRequests.remove(requestId);
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.completeError(
            TimeoutException(
              'Worker command "$command" timed out after $timeout.',
              timeout,
            ),
          );
        }
      });
    }

    _pendingRequests[requestId] = _PendingWorkerRequest(
      command: command,
      completer: completer,
      timeoutTimer: timeoutTimer,
    );

    try {
      _workerSendPort!.send(<String, Object?>{
        _kTypeKey: _kRequestType,
        _kRequestIdKey: requestId,
        _kCommandKey: command,
        _kPayloadKey: payload,
      });
    } catch (error) {
      final pending = _pendingRequests.remove(requestId);
      pending?.timeoutTimer?.cancel();
      throw IsolateWorkerPayloadException(
        'Failed sending command "$command" to worker: $error',
      );
    }

    final result = await completer.future;
    return result as R;
  }

  /// Disposes the spawned worker isolate and associated communication ports.
  ///
  /// Pending requests fail with [IsolateWorkerDisposedException].
  Future<void> disposeWorker() async {
    if (_workerState == _WorkerState.disposing) {
      await (_disposeFuture ?? Future<void>.value());
      return;
    }

    if (_workerState == _WorkerState.starting) {
      await (_spawnFuture?.catchError((_) {}) ?? Future<void>.value());
    }

    if (_workerState == _WorkerState.stopped) {
      _detachWorkerLeakWarning();
      return;
    }

    final disposeCompleter = Completer<void>();
    _disposeFuture = disposeCompleter.future;
    _workerState = _WorkerState.disposing;

    try {
      try {
        _workerSendPort?.send(<String, Object?>{_kTypeKey: _kDisposeType});
      } catch (_) {
        // Best-effort signal; isolate is killed below.
      }

      _workerIsolate?.kill(priority: Isolate.immediate);
      _failPendingRequests(
        const IsolateWorkerDisposedException(
          'Worker disposed before request completion.',
        ),
      );
      await _resetWorkerRuntimeResources();
      _workerState = _WorkerState.stopped;
    } finally {
      _startupCompleter = null;
      _disposeFuture = null;
      _detachWorkerLeakWarning();
      if (!disposeCompleter.isCompleted) {
        disposeCompleter.complete();
      }
    }
  }

  Future<T> _runInAutoMode<T>(FutureOr<T> Function() fn) async {
    final token = RootIsolateToken.instance;
    if (token == null) {
      return await Future<T>.sync(fn);
    }

    return await _runInBackgroundIsolate(fn, token: token);
  }

  Future<T> _runInBackgroundIsolate<T>(
    FutureOr<T> Function() fn, {
    RootIsolateToken? token,
  }) async {
    final task = _IsolateTask<T>(token, fn);
    return await Isolate.run(() => _isolateEntryPoint(task));
  }

  Future<void> _ensureWorkerReadyForRequest() async {
    if (_workerState == _WorkerState.running) {
      return;
    }

    if (_workerState == _WorkerState.disposing) {
      await (_disposeFuture ?? Future<void>.value());
    }

    if (_registeredWorkerHandler == null) {
      throw const IsolateWorkerNotInitializedException(
        'No worker handler registered. Call spawnWorker(handler: ...) first.',
      );
    }

    await _ensureWorkerSpawned(
      handler: _registeredWorkerHandler!,
      options: _spawnWorkerOptions,
    );
  }

  Future<void> _ensureWorkerSpawned({
    required IsolateWorkerHandler handler,
    required SpawnWorkerOptions options,
  }) async {
    // Loop instead of recursing to safely handle the disposing → stopped
    // transition without unbounded call-stack growth.
    while (true) {
      if (_workerState == _WorkerState.running) return;
      if (_workerState == _WorkerState.starting) {
        assert(
          _spawnFuture != null,
          '_spawnFuture must be non-null while in starting state.',
        );
        await (_spawnFuture ?? Future<void>.value());
        return;
      }
      if (_workerState == _WorkerState.disposing) {
        await (_disposeFuture ?? Future<void>.value());
        continue;
      }
      break; // _WorkerState.stopped — proceed to spawn.
    }

    final startupFuture = _spawnWorkerInternal(handler, options);
    _spawnFuture = startupFuture;
    _workerState = _WorkerState.starting;
    try {
      await startupFuture;
      _workerState = _WorkerState.running;
      _activeWorkerHandler = handler;
      _activeSpawnWorkerOptions = options;
      _attachWorkerLeakWarning();
    } catch (error) {
      _workerState = _WorkerState.stopped;
      rethrow;
    } finally {
      if (identical(_spawnFuture, startupFuture)) {
        _spawnFuture = null;
      }
    }
  }

  Future<void> _spawnWorkerInternal(
    IsolateWorkerHandler handler,
    SpawnWorkerOptions options,
  ) async {
    _startupCompleter = Completer<void>();

    _workerMessagePort = ReceivePort();
    _workerErrorPort = ReceivePort();
    _workerExitPort = ReceivePort();

    _workerMessageSubscription = _workerMessagePort!.cast<Object?>().listen(
      _handleWorkerMessage,
    );
    _workerErrorSubscription = _workerErrorPort!.cast<Object?>().listen(
      _handleWorkerError,
    );
    _workerExitSubscription = _workerExitPort!.cast<Object?>().listen(
      _handleWorkerExit,
    );

    try {
      _workerIsolate = await Isolate.spawn<Object?>(
        _workerIsolateEntryPoint,
        <String, Object?>{
          _kMainSendPortKey: _workerMessagePort!.sendPort,
          _kTokenKey: RootIsolateToken.instance,
          _kHandlerKey: handler,
        },
        errorsAreFatal: true,
      );
      _workerIsolate!.addErrorListener(_workerErrorPort!.sendPort);
      _workerIsolate!.addOnExitListener(
        _workerExitPort!.sendPort,
        response: _kExitSignal,
      );
    } catch (error) {
      await _resetWorkerRuntimeResources();
      throw IsolateWorkerException(
        'Failed to spawn worker. Ensure handler is top-level/static and '
        'captures only sendable values. Original error: $error',
      );
    }

    Future<void> startup = _startupCompleter!.future;
    final startupTimeout = options.startupTimeout;
    if (startupTimeout != null) {
      startup = startup.timeout(startupTimeout);
    }

    try {
      await startup;
    } catch (error) {
      _workerIsolate?.kill(priority: Isolate.immediate);
      await _resetWorkerRuntimeResources();
      rethrow;
    } finally {
      _startupCompleter = null;
    }
  }

  void _handleWorkerMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }

    final type = message[_kTypeKey] as String?;
    switch (type) {
      case _kReadyType:
        _workerSendPort = message[_kWorkerSendPortKey] as SendPort?;
        if (_workerSendPort == null) {
          _completeStartupError(
            const IsolateWorkerException(
              'Worker startup failed: missing worker send port.',
            ),
          );
          return;
        }
        _completeStartupReady();
        return;
      case _kResponseType:
        final requestId = message[_kRequestIdKey] as int?;
        if (requestId == null) {
          return;
        }
        final pending = _pendingRequests.remove(requestId);
        if (pending == null) {
          return;
        }
        pending.timeoutTimer?.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.complete(message[_kResultKey]);
        }
        return;
      case _kErrorType:
        final requestId = message[_kRequestIdKey] as int?;
        if (requestId == null) {
          return;
        }
        final pending = _pendingRequests.remove(requestId);
        if (pending == null) {
          return;
        }
        pending.timeoutTimer?.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.completeError(
            IsolateWorkerRemoteException(
              command: pending.command,
              remoteError: message[_kErrorMessageKey]?.toString() ?? 'Unknown',
              remoteStackTrace: message[_kStackTraceKey]?.toString(),
            ),
          );
        }
        return;
      default:
        // Ignore unknown message types.
        return;
    }
  }

  void _handleWorkerError(Object? message) {
    final parsed = _parseWorkerError(message);
    _handleWorkerTermination(
      IsolateWorkerTerminatedException(
        'Worker crashed: ${parsed.$1}',
        workerStackTrace: parsed.$2,
      ),
    );
  }

  void _handleWorkerExit(Object? _) {
    if (_workerState == _WorkerState.disposing) {
      return;
    }

    _handleWorkerTermination(
      const IsolateWorkerTerminatedException('Worker exited unexpectedly.'),
    );
  }

  (String, String?) _parseWorkerError(Object? message) {
    if (message is List) {
      final list = message.cast<Object?>();
      final error = list.isNotEmpty ? list.first : 'Unknown worker error';
      final stackTrace = list.length > 1 ? list[1] : null;
      return (error.toString(), stackTrace?.toString());
    }
    return (message.toString(), null);
  }

  void _handleWorkerTermination(IsolateWorkerTerminatedException exception) {
    _completeStartupError(exception);
    _failPendingRequests(exception);
    _detachWorkerLeakWarning();

    // Synchronously sever all references before updating state so that any
    // concurrent requestWorker call sees a fully clean slate on re-entry.
    final messageSub = _workerMessageSubscription;
    final errorSub = _workerErrorSubscription;
    final exitSub = _workerExitSubscription;
    final msgPort = _workerMessagePort;
    final errPort = _workerErrorPort;
    final exitPort = _workerExitPort;
    _workerIsolate = null;
    _workerSendPort = null;
    _workerMessageSubscription = null;
    _workerErrorSubscription = null;
    _workerExitSubscription = null;
    _workerMessagePort = null;
    _workerErrorPort = null;
    _workerExitPort = null;
    _activeWorkerHandler = null;
    _activeSpawnWorkerOptions = null;

    _workerState = _WorkerState.stopped;

    // Cancel subscriptions and close ports asynchronously (best-effort).
    unawaited(
      Future.wait<void>([
        messageSub?.cancel() ?? Future<void>.value(),
        errorSub?.cancel() ?? Future<void>.value(),
        exitSub?.cancel() ?? Future<void>.value(),
      ]),
    );
    msgPort?.close();
    errPort?.close();
    exitPort?.close();
  }

  void _completeStartupReady() {
    final completer = _startupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _completeStartupError(Object error, [StackTrace? stackTrace]) {
    final completer = _startupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  void _failPendingRequests(Object error, [StackTrace? stackTrace]) {
    final keys = _pendingRequests.keys.toList(growable: false);
    for (final int requestId in keys) {
      final pending = _pendingRequests.remove(requestId);
      if (pending == null) {
        continue;
      }
      pending.timeoutTimer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _resetWorkerRuntimeResources() async {
    _workerIsolate = null;
    _workerSendPort = null;

    final messageSub = _workerMessageSubscription;
    final errorSub = _workerErrorSubscription;
    final exitSub = _workerExitSubscription;
    _workerMessageSubscription = null;
    _workerErrorSubscription = null;
    _workerExitSubscription = null;

    await messageSub?.cancel();
    await errorSub?.cancel();
    await exitSub?.cancel();

    _workerMessagePort?.close();
    _workerErrorPort?.close();
    _workerExitPort?.close();
    _workerMessagePort = null;
    _workerErrorPort = null;
    _workerExitPort = null;
    _activeWorkerHandler = null;
    _activeSpawnWorkerOptions = null;
  }

  bool _isCurrentWorkerConfiguration(
    IsolateWorkerHandler handler,
    SpawnWorkerOptions options,
  ) {
    return identical(_activeWorkerHandler, handler) &&
        _activeSpawnWorkerOptions == options;
  }

  void _attachWorkerLeakWarning() {
    _workerLeakFinalizer.detach(_workerLeakDetachToken);
    _workerLeakFinalizer.attach(
      this,
      _WorkerLeakTrace(
        ownerType: runtimeType.toString(),
        spawnStackTrace: StackTrace.current.toString(),
      ),
      detach: _workerLeakDetachToken,
    );
  }

  void _detachWorkerLeakWarning() {
    _workerLeakFinalizer.detach(_workerLeakDetachToken);
  }
}
