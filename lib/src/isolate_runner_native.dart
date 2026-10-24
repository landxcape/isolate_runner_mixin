import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:isolate_runner_mixin/src/isolate_models.dart';

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

// ------------------- Isolate Communication Models (Top-level) --------------------

class _IsolateTask<T> {
  final RootIsolateToken? token;
  final FutureOr<T> Function() task;

  _IsolateTask(this.token, this.task);
}

// ------------------- Isolate Entry Point (Top-level Function) --------------------

Future<T> _isolateEntryPoint<T>(_IsolateTask<T> task) async {
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
      if (!isAllowedPayload(result)) {
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

// ------------------- The IsolateRunnerMixin --------------------

/// A mixin to provide a convenient `runInIsolate` method to any class.
mixin IsolateRunnerMixin {
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

  WorkerState _workerState = WorkerState.stopped;
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
  bool get isWorkerRunning => _workerState == WorkerState.running;

  /// Runs the given [fn] in a background isolate.
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
  Future<R> runInIsolateWithArg<A, R>(
    A argument,
    FutureOr<R> Function(A argument) fn, {
    IsolateRunMode mode = IsolateRunMode.auto,
    Duration? timeout,
  }) async {
    return await runInIsolate(() => fn(argument), mode: mode, timeout: timeout);
  }

  /// Spawns a persistent worker isolate.
  Future<void> spawnWorker({
    required IsolateWorkerHandler handler,
    SpawnWorkerOptions options = const SpawnWorkerOptions(),
  }) async {
    if (_workerState == WorkerState.starting) {
      await (_spawnFuture ?? Future<void>.value());
    }

    _registeredWorkerHandler = handler;
    _spawnWorkerOptions = options;

    if (_workerState == WorkerState.running &&
        !_isCurrentWorkerConfiguration(handler, options)) {
      await disposeWorker();
    }

    await _ensureWorkerSpawned(handler: handler, options: options);
  }

  /// Sends a request to the spawned worker isolate.
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

    await _ensureWorkerReadyForRequest();

    if (_workerSendPort == null || _workerState != WorkerState.running) {
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
    } catch (error, stackTrace) {
      timeoutTimer?.cancel();
      _pendingRequests.remove(requestId);
      Error.throwWithStackTrace(
        IsolateWorkerPayloadException(
          'Failed to send request payload for command "$command": $error',
        ),
        stackTrace,
      );
    }

    final response = await completer.future;
    return response as R;
  }

  /// Disposes the worker isolate and closes all ports.
  Future<void> disposeWorker() async {
    if (_workerState == WorkerState.stopped) {
      return;
    }

    if (_disposeFuture != null) {
      return await _disposeFuture!;
    }

    _disposeFuture = _disposeWorkerInternal();
    try {
      await _disposeFuture!;
    } finally {
      _disposeFuture = null;
    }
  }

  Future<void> _disposeWorkerInternal() async {
    _workerState = WorkerState.disposing;
    _workerLeakFinalizer.detach(_workerLeakDetachToken);

    if (_startupCompleter != null && !_startupCompleter!.isCompleted) {
      _startupCompleter!.completeError(
        const IsolateWorkerDisposedException(
          'Worker startup was aborted because the worker was disposed.',
        ),
      );
    }

    final sendPort = _workerSendPort;
    if (sendPort != null) {
      try {
        sendPort.send(<String, Object?>{_kTypeKey: _kDisposeType});
      } catch (_) {
        // Best effort notification; isolate kill below guarantees stop.
      }
    }

    await _workerMessageSubscription?.cancel();
    await _workerErrorSubscription?.cancel();
    await _workerExitSubscription?.cancel();

    _workerMessageSubscription = null;
    _workerErrorSubscription = null;
    _workerExitSubscription = null;

    _workerMessagePort?.close();
    _workerErrorPort?.close();
    _workerExitPort?.close();

    _workerMessagePort = null;
    _workerErrorPort = null;
    _workerExitPort = null;

    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;

    _activeWorkerHandler = null;
    _activeSpawnWorkerOptions = null;
    _spawnFuture = null;
    _startupCompleter = null;

    _failPendingRequests(
      const IsolateWorkerDisposedException(
        'Worker was disposed while this request was pending.',
      ),
    );

    _workerState = WorkerState.stopped;
  }

  Future<void> _ensureWorkerReadyForRequest() async {
    if (_workerState == WorkerState.running && _workerSendPort != null) {
      return;
    }

    if (_workerState == WorkerState.starting) {
      await (_spawnFuture ?? Future<void>.value());
      return;
    }

    if (_workerState == WorkerState.stopped) {
      final handler = _registeredWorkerHandler;
      if (handler == null) {
        throw const IsolateWorkerNotInitializedException(
          'Cannot send request: worker handler is not initialized. '
          'Call spawnWorker() first.',
        );
      }
      await spawnWorker(handler: handler, options: _spawnWorkerOptions);
      return;
    }

    if (_workerState == WorkerState.disposing) {
      throw const IsolateWorkerDisposedException(
        'Cannot send request while the worker is being disposed.',
      );
    }
  }

  Future<void> _ensureWorkerSpawned({
    required IsolateWorkerHandler handler,
    required SpawnWorkerOptions options,
  }) async {
    if (_workerState == WorkerState.running &&
        _isCurrentWorkerConfiguration(handler, options)) {
      return;
    }

    if (_workerState == WorkerState.starting) {
      await (_spawnFuture ?? Future<void>.value());
      return;
    }

    _spawnFuture = _spawnWorkerInternal(handler: handler, options: options);
    try {
      await _spawnFuture!;
    } finally {
      _spawnFuture = null;
    }
  }

  Future<void> _spawnWorkerInternal({
    required IsolateWorkerHandler handler,
    required SpawnWorkerOptions options,
  }) async {
    _workerState = WorkerState.starting;
    _startupCompleter = Completer<void>();

    final startupTimer = options.startupTimeout == null
        ? null
        : Timer(options.startupTimeout!, () {
            if (_startupCompleter != null && !_startupCompleter!.isCompleted) {
              _startupCompleter!.completeError(
                TimeoutException(
                  'Worker isolate startup timed out after ${options.startupTimeout}.',
                  options.startupTimeout,
                ),
              );
            }
          });

    try {
      final messagePort = ReceivePort();
      final errorPort = ReceivePort();
      final exitPort = ReceivePort();

      _workerMessagePort = messagePort;
      _workerErrorPort = errorPort;
      _workerExitPort = exitPort;

      _workerMessageSubscription = messagePort.listen(_handleWorkerMessage);
      _workerErrorSubscription = errorPort.listen(_handleWorkerError);
      _workerExitSubscription = exitPort.listen(_handleWorkerExit);

      final token = RootIsolateToken.instance;
      _workerIsolate = await Isolate.spawn(
        _workerIsolateEntryPoint,
        <String, Object?>{
          _kMainSendPortKey: messagePort.sendPort,
          _kTokenKey: token,
          _kHandlerKey: handler,
        },
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );

      await _startupCompleter!.future;
      startupTimer?.cancel();

      _activeWorkerHandler = handler;
      _activeSpawnWorkerOptions = options;
      _workerState = WorkerState.running;

      _workerLeakFinalizer.attach(
        this,
        _WorkerLeakTrace(
          ownerType: runtimeType.toString(),
          spawnStackTrace: StackTrace.current.toString(),
        ),
        detach: _workerLeakDetachToken,
      );
    } catch (error) {
      startupTimer?.cancel();
      await _cleanupFailedSpawn();
      rethrow;
    }
  }

  void _handleWorkerMessage(Object? message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }

    final type = message[_kTypeKey] as String?;
    if (type == _kReadyType) {
      _workerSendPort = message[_kWorkerSendPortKey] as SendPort?;
      if (_startupCompleter != null && !_startupCompleter!.isCompleted) {
        _startupCompleter!.complete();
      }
      return;
    }

    final requestId = message[_kRequestIdKey] as int?;
    if (requestId == null) {
      return;
    }

    final pending = _pendingRequests.remove(requestId);
    if (pending == null) {
      return;
    }

    pending.timeoutTimer?.cancel();

    if (type == _kResponseType) {
      final result = message[_kResultKey];
      pending.completer.complete(result);
      return;
    }

    if (type == _kErrorType) {
      final errorMsg = message[_kErrorMessageKey] as String? ?? 'Unknown error';
      final stackTrace = message[_kStackTraceKey] as String?;
      pending.completer.completeError(
        IsolateWorkerRemoteException(
          command: pending.command,
          remoteError: errorMsg,
          remoteStackTrace: stackTrace,
        ),
      );
    }
  }

  void _handleWorkerError(Object? errorEvent) {
    String errorString = 'Worker isolate crashed with unhandled exception.';
    String? stackTraceString;

    if (errorEvent is List && errorEvent.isNotEmpty) {
      errorString = errorEvent[0]?.toString() ?? errorString;
      if (errorEvent.length > 1) {
        stackTraceString = errorEvent[1]?.toString();
      }
    } else if (errorEvent != null) {
      errorString = errorEvent.toString();
    }

    _failPendingRequests(
      IsolateWorkerTerminatedException(
        errorString,
        workerStackTrace: stackTraceString,
      ),
    );

    _workerState = WorkerState.stopped;
  }

  void _handleWorkerExit(Object? _) {
    if (_workerState == WorkerState.disposing ||
        _workerState == WorkerState.stopped) {
      return;
    }

    _failPendingRequests(
      const IsolateWorkerTerminatedException(
        'Worker isolate terminated unexpectedly.',
      ),
    );

    _workerState = WorkerState.stopped;
  }

  void _failPendingRequests(IsolateWorkerException exception) {
    final pendingCopy = List<_PendingWorkerRequest>.from(
      _pendingRequests.values,
    );
    _pendingRequests.clear();

    for (final request in pendingCopy) {
      request.timeoutTimer?.cancel();
      if (!request.completer.isCompleted) {
        request.completer.completeError(exception);
      }
    }
  }

  Future<void> _cleanupFailedSpawn() async {
    _workerLeakFinalizer.detach(_workerLeakDetachToken);
    await _workerMessageSubscription?.cancel();
    await _workerErrorSubscription?.cancel();
    await _workerExitSubscription?.cancel();

    _workerMessagePort?.close();
    _workerErrorPort?.close();
    _workerExitPort?.close();

    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;
    _workerState = WorkerState.stopped;
  }

  bool _isCurrentWorkerConfiguration(
    IsolateWorkerHandler handler,
    SpawnWorkerOptions options,
  ) {
    return identical(_activeWorkerHandler, handler) &&
        _activeSpawnWorkerOptions == options;
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
    required RootIsolateToken? token,
  }) async {
    final task = _IsolateTask<T>(token, fn);
    return await Isolate.run(() => _isolateEntryPoint<T>(task));
  }
}
