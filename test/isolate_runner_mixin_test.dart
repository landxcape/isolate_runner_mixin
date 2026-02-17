import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

class _Runner with IsolateRunnerMixin {}

class _NotSendable {
  final int value;

  const _NotSendable(this.value);
}

int _currentIsolateHash() => Isolate.current.hashCode;

int _double(int input) => input * 2;

Future<String> _asyncValue() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  return 'done';
}

Future<void> _slowTask() async {
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

Never _throwsStateError() {
  throw StateError('boom');
}

FutureOr<Object?> _workerHandler(String command, Object? payload) async {
  switch (command) {
    case 'isolateHash':
      return Isolate.current.hashCode;
    case 'echo':
      return payload;
    case 'delayEcho':
      final map = payload as Map<Object?, Object?>;
      final delayMs = map['delayMs'] as int;
      final value = map['value'];
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      return value;
    case 'throw':
      throw StateError('remote boom');
  }
  throw UnsupportedError('Unknown command: $command');
}

FutureOr<Object?> _workerHandlerV2(String command, Object? payload) async {
  switch (command) {
    case 'isolateHash':
      return Isolate.current.hashCode;
    case 'echo':
      return <String, Object?>{'v2': payload};
  }
  throw UnsupportedError('Unknown command: $command');
}

void main() {
  group('IsolateRunnerMixin', () {
    late _Runner runner;

    setUp(() {
      runner = _Runner();
    });

    tearDown(() async {
      await runner.disposeWorker();
    });

    test('returns result for synchronous work', () async {
      final result = await runner.runInIsolate(() => 42);
      expect(result, 42);
    });

    test('returns result for asynchronous work', () async {
      final result = await runner.runInIsolate(_asyncValue);
      expect(result, 'done');
    });

    test('currentIsolate mode executes on current isolate', () async {
      final mainHash = _currentIsolateHash();
      final isolateHash = await runner.runInIsolate(
        _currentIsolateHash,
        mode: IsolateRunMode.currentIsolate,
      );

      expect(isolateHash, mainHash);
    });

    test('alwaysIsolate mode executes on a background isolate', () async {
      final mainHash = _currentIsolateHash();
      final isolateHash = await runner.runInIsolate(
        _currentIsolateHash,
        mode: IsolateRunMode.alwaysIsolate,
      );

      expect(isolateHash, isNot(mainHash));
    });

    test('auto mode follows RootIsolateToken availability', () async {
      final mainHash = _currentIsolateHash();
      final isolateHash = await runner.runInIsolate(
        _currentIsolateHash,
        mode: IsolateRunMode.auto,
      );

      if (RootIsolateToken.instance == null) {
        expect(isolateHash, mainHash);
      } else {
        expect(isolateHash, isNot(mainHash));
      }
    });

    test('runInIsolateWithArg passes argument to task', () async {
      final result = await runner.runInIsolateWithArg<int, int>(
        21,
        _double,
        mode: IsolateRunMode.alwaysIsolate,
      );

      expect(result, 42);
    });

    test('rethrows task errors in current isolate mode', () async {
      expect(
        () => runner.runInIsolate(
          _throwsStateError,
          mode: IsolateRunMode.currentIsolate,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rethrows task errors in background isolate mode', () async {
      expect(
        () => runner.runInIsolate(
          _throwsStateError,
          mode: IsolateRunMode.alwaysIsolate,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('throws TimeoutException when task exceeds timeout', () async {
      expect(
        () => runner.runInIsolate(
          _slowTask,
          mode: IsolateRunMode.alwaysIsolate,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('requestWorker throws when spawnWorker was never called', () async {
      await expectLater(
        runner.requestWorker<int>(command: 'echo', payload: 1),
        throwsA(isA<IsolateWorkerNotInitializedException>()),
      );
    });

    test('spawnWorker is idempotent when already running', () async {
      await runner.spawnWorker(handler: _workerHandler);
      final firstHash = await runner.requestWorker<int>(command: 'isolateHash');

      await runner.spawnWorker(handler: _workerHandler);
      final secondHash = await runner.requestWorker<int>(
        command: 'isolateHash',
      );

      expect(firstHash, secondHash);
      expect(runner.isWorkerRunning, isTrue);
    });

    test('spawnWorker dedupes concurrent startup calls', () async {
      await Future.wait(<Future<void>>[
        runner.spawnWorker(handler: _workerHandler),
        runner.spawnWorker(handler: _workerHandler),
        runner.spawnWorker(handler: _workerHandler),
      ]);

      final hash = await runner.requestWorker<int>(command: 'isolateHash');
      expect(hash, isA<int>());
      expect(runner.isWorkerRunning, isTrue);
    });

    test(
      'spawnWorker reconfigures running worker when handler changes',
      () async {
        await runner.spawnWorker(handler: _workerHandler);
        final firstHash = await runner.requestWorker<int>(
          command: 'isolateHash',
        );
        final firstResult = await runner.requestWorker<Object?>(
          command: 'echo',
          payload: 1,
        );
        expect(firstResult, 1);

        await runner.spawnWorker(handler: _workerHandlerV2);
        final secondHash = await runner.requestWorker<int>(
          command: 'isolateHash',
        );
        final secondResult = await runner.requestWorker<Map<Object?, Object?>>(
          command: 'echo',
          payload: 1,
        );

        expect(secondHash, isNot(firstHash));
        expect(secondResult, <String, Object?>{'v2': 1});
      },
    );

    test(
      'spawnWorker reconfigures running worker when options change',
      () async {
        await runner.spawnWorker(
          handler: _workerHandler,
          options: const SpawnWorkerOptions(maxPendingRequests: 10),
        );
        final firstHash = await runner.requestWorker<int>(
          command: 'isolateHash',
        );

        await runner.spawnWorker(
          handler: _workerHandler,
          options: const SpawnWorkerOptions(maxPendingRequests: 999),
        );
        final secondHash = await runner.requestWorker<int>(
          command: 'isolateHash',
        );

        expect(secondHash, isNot(firstHash));
      },
    );

    test('requestWorker processes requests sequentially', () async {
      await runner.spawnWorker(handler: _workerHandler);

      final completionOrder = <int>[];
      final first = runner
          .requestWorker<int>(
            command: 'delayEcho',
            payload: <String, Object?>{'value': 1, 'delayMs': 80},
          )
          .then((value) {
            completionOrder.add(value);
            return value;
          });
      final second = runner
          .requestWorker<int>(
            command: 'delayEcho',
            payload: <String, Object?>{'value': 2, 'delayMs': 0},
          )
          .then((value) {
            completionOrder.add(value);
            return value;
          });

      final results = await Future.wait(<Future<int>>[first, second]);
      expect(results, <int>[1, 2]);
      expect(completionOrder, <int>[1, 2]);
    });

    test('enforces maxPendingRequests', () async {
      await runner.spawnWorker(
        handler: _workerHandler,
        options: const SpawnWorkerOptions(maxPendingRequests: 1),
      );

      final firstRequest = runner.requestWorker<int>(
        command: 'delayEcho',
        payload: <String, Object?>{'value': 1, 'delayMs': 120},
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await expectLater(
        runner.requestWorker<int>(command: 'echo', payload: 2),
        throwsA(isA<IsolateWorkerQueueOverflowException>()),
      );

      expect(await firstRequest, 1);
    });

    test('propagates worker handler errors', () async {
      await runner.spawnWorker(handler: _workerHandler);

      await expectLater(
        runner.requestWorker<void>(command: 'throw'),
        throwsA(isA<IsolateWorkerRemoteException>()),
      );
    });

    test('request timeout removes pending and allows next request', () async {
      await runner.spawnWorker(handler: _workerHandler);

      await expectLater(
        runner.requestWorker<int>(
          command: 'delayEcho',
          payload: <String, Object?>{'value': 1, 'delayMs': 150},
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );

      final result = await runner.requestWorker<int>(
        command: 'echo',
        payload: 99,
      );
      expect(result, 99);
    });

    test('disposeWorker fails pending requests and resets state', () async {
      await runner.spawnWorker(handler: _workerHandler);

      final pending = runner.requestWorker<int>(
        command: 'delayEcho',
        payload: <String, Object?>{'value': 7, 'delayMs': 300},
      );
      final pendingExpectation = expectLater(
        pending,
        throwsA(isA<IsolateWorkerDisposedException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await runner.disposeWorker();
      expect(runner.isWorkerRunning, isFalse);
      await pendingExpectation;
    });

    test('requestWorker auto-respawns after dispose', () async {
      await runner.spawnWorker(handler: _workerHandler);
      await runner.requestWorker<int>(command: 'isolateHash');
      await runner.disposeWorker();

      expect(runner.isWorkerRunning, isFalse);

      final value = await runner.requestWorker<int>(
        command: 'echo',
        payload: 5,
      );
      expect(value, 5);
      expect(runner.isWorkerRunning, isTrue);
    });

    test(
      'runInIsolate remains independent from spawned worker state',
      () async {
        await runner.spawnWorker(handler: _workerHandler);
        final workerHash = await runner.requestWorker<int>(
          command: 'isolateHash',
        );

        final oneOffHash = await runner.runInIsolate(
          _currentIsolateHash,
          mode: IsolateRunMode.alwaysIsolate,
        );
        final workerHashAfter = await runner.requestWorker<int>(
          command: 'isolateHash',
        );

        expect(oneOffHash, isA<int>());
        expect(workerHashAfter, workerHash);
      },
    );

    test('validates payload contract before sending request', () async {
      await runner.spawnWorker(handler: _workerHandler);

      await expectLater(
        runner.requestWorker<Object?>(
          command: 'echo',
          payload: const _NotSendable(1),
        ),
        throwsA(isA<IsolateWorkerPayloadException>()),
      );
    });
  });
}
