import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:isolate_runner_mixin/src/isolate_models.dart';
import 'package:isolate_runner_mixin/src/isolate_runner_web.dart';

class _TestWebService with IsolateRunnerMixin {}

void main() {
  group('IsolateRunnerMixin Web Runner', () {
    late _TestWebService service;

    setUp(() {
      service = _TestWebService();
    });

    tearDown(() async {
      await service.disposeWorker();
    });

    test('runInIsolate executes and yields on web event loop', () async {
      final result = await service.runInIsolate(() => 40 + 2);
      expect(result, equals(42));
    });

    test('runInIsolateWithArg passes argument properly', () async {
      final result = await service.runInIsolateWithArg<int, int>(
        21,
        (arg) => arg * 2,
      );
      expect(result, equals(42));
    });

    test('spawnWorker registers handler and processes requestWorker', () async {
      await service.spawnWorker(
        handler: (command, payload) async {
          if (command == 'echo') {
            return 'processed:$payload';
          }
          throw UnsupportedError('Unknown: $command');
        },
      );

      expect(service.isWorkerRunning, isTrue);

      final response = await service.requestWorker<String>(
        command: 'echo',
        payload: 'hello',
      );
      expect(response, equals('processed:hello'));
    });

    test('requestWorker validates payload constraints', () async {
      await service.spawnWorker(handler: (cmd, payload) => 'ok');

      final circularList = <Object?>[];
      circularList.add(circularList);

      expect(
        () => service.requestWorker<String>(
          command: 'invalid',
          payload: circularList,
        ),
        throwsA(isA<IsolateWorkerPayloadException>()),
      );
    });

    test(
      'requestWorker wraps handler errors in IsolateWorkerRemoteException',
      () async {
        await service.spawnWorker(
          handler: (cmd, payload) => throw StateError('Boom in web worker'),
        );

        expect(
          () => service.requestWorker<String>(command: 'fail', payload: 'data'),
          throwsA(isA<IsolateWorkerRemoteException>()),
        );
      },
    );

    test('disposeWorker cancels in-flight requests and resets state', () async {
      final completer = Completer<String>();
      await service.spawnWorker(handler: (cmd, payload) => completer.future);

      final inFlight = service.requestWorker<String>(
        command: 'wait',
        payload: null,
      );

      final expectation = expectLater(
        inFlight,
        throwsA(isA<IsolateWorkerDisposedException>()),
      );

      await service.disposeWorker();
      expect(service.isWorkerRunning, isFalse);

      await expectation;
    });
  });
}
