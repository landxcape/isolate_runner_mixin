# isolate_runner_mixin

A Flutter mixin for running work off the UI isolate.

It gives you two APIs:

- `runInIsolate`: one-off work
- `spawnWorker` + `requestWorker`: long-lived worker isolate

## Quick start

Use this when you are starting:

- Use `runInIsolate` if you only need one background call.
- Use `spawnWorker` + `requestWorker` if you need many calls over time.

Minimum one-off example:

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

int _sum(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) {
    total += i;
  }
  return total;
}

class MyService with IsolateRunnerMixin {
  Future<int> compute(int n) {
    return runInIsolate(() => _sum(n));
  }
}
```

## What `runInIsolate` receives

```dart
await runInIsolate(() {
  // heavy code
  return computeSomething();
});
```

You pass a callback. The callback body runs in the target isolate.

You are not passing a precomputed value.

```dart
final x = heavyCalc(); // runs on main isolate right now
await runInIsolate(() => x);
```

In this case, `heavyCalc()` already ran on the main isolate.

## Rules for reliable usage

1. Keep heavy work inside the callback body.
2. Prefer top-level or `static` functions for isolate code.
3. Send only supported payload/result types (`null`, primitives, `List`, `Map`,
   `TransferableTypedData`, `SendPort`).
4. If you use `spawnWorker`, call `disposeWorker()` in your owner lifecycle.

## Installation

```yaml
dependencies:
  isolate_runner_mixin: <latest_version>
```

Run `flutter pub get`.

## Usage: One-Off Tasks

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

int _sum(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) {
    total += i;
  }
  return total;
}

class MyService with IsolateRunnerMixin {
  Future<int> heavyComputation(int n) {
    return runInIsolate(
      () => _sum(n),
      mode: IsolateRunMode.alwaysIsolate,
      timeout: const Duration(seconds: 3),
    );
  }
}
```

### Modes

- `IsolateRunMode.auto`: background isolate only when a `RootIsolateToken` is
  available, otherwise current isolate.
- `IsolateRunMode.alwaysIsolate`: always background isolate.
- `IsolateRunMode.currentIsolate`: always current isolate.

### Preferred pattern

```dart
// top-level or static function
bool _verify(String data, String sig, String pubKey) {
  // Verification logic
  return true;
}

class MyService with IsolateRunnerMixin {
  final String publicKey;
  MyService(this.publicKey);

  Future<bool> verify(String data, String signature) {
    return runInIsolate(
      () => _verify(data, signature, publicKey),
      mode: IsolateRunMode.alwaysIsolate,
    );
  }
}
```

## Usage: Persistent Worker

Use a persistent worker when you need many requests over time.
The handler should be top-level or `static`.

```dart
import 'dart:async';

FutureOr<Object?> workerHandler(String command, Object? payload) async {
  switch (command) {
    case 'double':
      return (payload as int) * 2;
    case 'delayEcho':
      final map = payload as Map<Object?, Object?>;
      await Future<void>.delayed(Duration(milliseconds: map['delayMs'] as int));
      return map['value'];
  }
  throw UnsupportedError('Unknown command: $command');
}
```

Initialize once, then send requests:

```dart
class MyService with IsolateRunnerMixin {
  Future<void> init() async {
    await spawnWorker(
      handler: workerHandler,
      options: const SpawnWorkerOptions(maxPendingRequests: 500),
    );
  }

  Future<int> doubleValue(int input) {
    return requestWorker<int>(command: 'double', payload: input);
  }

  Future<void> dispose() async {
    await disposeWorker();
  }
}
```

### Worker lifecycle

- `spawnWorker` is idempotent.
- If startup is in progress, other `spawnWorker` calls wait for the same startup.
- `requestWorker` auto-respawns after dispose (if handler was previously registered).
- Calling `spawnWorker` again with different handler/options restarts the
  worker with the new configuration.
- `disposeWorker` must be called when the owner lifecycle ends.

### Payload contract

`requestWorker` payloads and worker results must be sendable by this package
contract:

- `null`, `bool`, `num`, `String`
- `List`/`Map` (containing supported values)
- `TransferableTypedData`
- `SendPort`

Custom classes are not accepted directly. Convert to `Map`/`List`.

### Flutter Lifecycle Example

```dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

class _MyState extends State<MyWidget> with IsolateRunnerMixin {
  @override
  void initState() {
    super.initState();
    spawnWorker(handler: workerHandler);
  }

  @override
  void dispose() {
    unawaited(disposeWorker());
    super.dispose();
  }
}
```

In debug mode, the package prints a warning if `disposeWorker` is missed.

## Common mistakes

```dart
// Wrong: heavyCalc runs on main isolate before runInIsolate is called.
final value = heavyCalc();
await runInIsolate(() => value);
```

```dart
// Correct: heavyCalc runs in the target isolate.
await runInIsolate(() => heavyCalc());
```

```dart
// Wrong: custom class is not directly sendable as request payload.
await requestWorker(command: 'save', payload: MyModel(...));
```

```dart
// Correct: convert to map/list first.
await requestWorker(command: 'save', payload: myModel.toJson());
```

## Example App

For a complete app, see the `example/` directory.
