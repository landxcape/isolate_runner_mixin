# isolate_runner_mixin

A Flutter mixin for running work off the UI isolate.

It gives you two APIs:

- `runInIsolate`: one-off work in a background isolate
- `spawnWorker` + `requestWorker`: long-lived persistent worker isolate

## Quick start

- Use `runInIsolate` for a single background call.
- Use `spawnWorker` + `requestWorker` for many calls over time (e.g. repeated heavy computation in a service).

**One-off (via mixin instance):**

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

int _sum(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) total += i;
  return total;
}

class MyService with IsolateRunnerMixin {
  Future<int> compute(int n) {
    return runInIsolate(() => _sum(n));
  }
}
```

## Installation

```yaml
dependencies:
  isolate_runner_mixin: <latest_version>
```

Run `flutter pub get`.

---

## Usage: One-Off Tasks

### Instance API

Mix into any class and call `runInIsolate`:

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

bool _verify(String data, String sig, String pubKey) {
  // ... verification logic
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

Pass a single argument with `runInIsolateWithArg`:

```dart
Future<int> doubled(int value) {
  return runInIsolateWithArg(value, (v) => v * 2);
}
```

### What the callback receives

You pass a **closure**. The closure body runs in the target isolate — not the
call site:

```dart
// ✗ Wrong: _sum(n) runs on the main isolate right now.
final result = _sum(n);
await runInIsolate(() => result);

// ✓ Correct: _sum(n) runs inside the background isolate.
await runInIsolate(() => _sum(n));
```

### Modes

| Mode | Behaviour |
|------|-----------|
| `IsolateRunMode.auto` | Background isolate when a `RootIsolateToken` is available, otherwise falls back to the current isolate. Default. |
| `IsolateRunMode.alwaysIsolate` | Always spawns a background isolate. |
| `IsolateRunMode.currentIsolate` | Always runs on the current isolate (useful for testing). |

---

## Usage: Persistent Worker

Use a persistent worker when you need many requests over time. Requests are
processed **sequentially** — the worker handles one command at a time in the
order they are received.

The handler **must be a top-level or `static` function**:

```dart
import 'dart:async';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

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
      options: const SpawnWorkerOptions(
        maxPendingRequests: 500,        // queue overflow protection
        startupTimeout: Duration(seconds: 10), // optional startup deadline
      ),
    );
  }

  Future<int> doubleValue(int input) {
    return requestWorker<int>(
      command: 'double',
      payload: input,
      timeout: const Duration(seconds: 5), // optional per-request deadline
    );
  }

  bool get workerAlive => isWorkerRunning;

  Future<void> dispose() async {
    await disposeWorker();
  }
}
```

### Worker lifecycle

- `spawnWorker` is idempotent — safe to call multiple times while running.
- If startup is already in progress, other `spawnWorker` calls await the same startup future.
- Calling `spawnWorker` again with a different `handler` or `options` restarts the worker with the new configuration.
- `requestWorker` auto-respawns the worker after a dispose if a handler was previously registered.
- `isWorkerRunning` returns `true` when the worker isolate is alive.
- `disposeWorker` must be called when the owner lifecycle ends. Pending requests are failed with `IsolateWorkerDisposedException`.

### Payload contract

`requestWorker` payloads and worker results must be one of:

- `null`, `bool`, `num`, `String`
- `List` / `Map` (recursively containing supported types — no circular references)
- `TransferableTypedData`
- `SendPort`

Custom classes are not accepted directly — convert to `Map` / `List` first.
Circular references are detected and rejected before sending.

### Error handling

```dart
try {
  final result = await service.requestWorker<int>(command: 'double', payload: 5);
} on IsolateWorkerRemoteException catch (e) {
  // The handler threw inside the worker isolate.
  print('Command "${e.command}" failed: ${e.remoteError}');
  print(e.remoteStackTrace);
} on IsolateWorkerDisposedException catch (_) {
  // disposeWorker() was called while this request was pending.
} on IsolateWorkerQueueOverflowException catch (_) {
  // Too many pending requests — exceeded maxPendingRequests.
} on IsolateWorkerTerminatedException catch (_) {
  // The worker isolate crashed unexpectedly.
} on TimeoutException catch (_) {
  // Per-request timeout elapsed.
}
```

All exceptions extend `IsolateWorkerException`, so you can catch the base type
for a broad handler:

```dart
} on IsolateWorkerException catch (e) {
  print('Worker error: $e');
}
```

---

## Flutter Lifecycle Example

```dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

FutureOr<Object?> _workerHandler(String command, Object? payload) async {
  // ... handle commands
}

class _MyState extends State<MyWidget> with IsolateRunnerMixin {
  @override
  void initState() {
    super.initState();
    spawnWorker(handler: _workerHandler);
  }

  @override
  void dispose() {
    unawaited(disposeWorker());
    super.dispose();
  }
}
```

In debug mode, the package prints a warning if `disposeWorker` is missed.

---

## Rules for reliable usage

1. Keep heavy work **inside** the callback body — work done before the callback runs on the main isolate.
2. Prefer top-level or `static` functions for isolate/worker code.
3. Send only supported payload/result types (see payload contract above).
4. No circular references in payloads — they are rejected before sending.
5. If you use `spawnWorker`, call `disposeWorker()` in your owner lifecycle.

---

## Common mistakes

```dart
// ✗ Wrong: heavyCalc runs on the main isolate before runInIsolate is called.
final value = heavyCalc();
await runInIsolate(() => value);
```

```dart
// ✓ Correct: heavyCalc runs in the target isolate.
await runInIsolate(() => heavyCalc());
```

```dart
// ✗ Wrong: custom class is not directly sendable as request payload.
await requestWorker(command: 'save', payload: MyModel(...));
```

```dart
// ✓ Correct: convert to map/list first.
await requestWorker(command: 'save', payload: myModel.toJson());
```

```dart
// ✗ Wrong: circular reference is rejected (not sendable across isolates).
final map = <Object?, Object?>{};
map['self'] = map;
await requestWorker(command: 'echo', payload: map);
```

---

## Example App

For a complete app demonstrating both one-off (instance API) and persistent worker patterns, see the `example/` directory.
