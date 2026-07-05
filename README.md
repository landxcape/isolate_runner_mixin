# isolate_runner_mixin

A Flutter mixin for running work off the UI isolate.

It gives you two APIs:

- `runInIsolate` / `IsolateRunnerMixin.run`: one-off work
- `spawnWorker` + `requestWorker`: long-lived worker isolate

## Quick start

- Use `runInIsolate` (or the static `IsolateRunnerMixin.run`) if you only need one background call.
- Use `spawnWorker` + `requestWorker` if you need many calls over time.

**One-off (static — no class needed):**

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

int _sum(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) total += i;
  return total;
}

// Call directly, anywhere — no class or mixin instance required.
final result = await IsolateRunnerMixin.run(() => _sum(50000000));
```

**One-off (via mixin instance):**

```dart
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

### Static API

Use `IsolateRunnerMixin.run` when you don't want to (or can't) add the mixin to
a class:

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

// Works anywhere — top-level, static context, test code, etc.
final result = await IsolateRunnerMixin.run(
  () => expensiveComputation(data),
  mode: IsolateRunMode.alwaysIsolate,
  timeout: const Duration(seconds: 5),
);
```

Pass a single argument with `IsolateRunnerMixin.runWithArg`:

```dart
final result = await IsolateRunnerMixin.runWithArg<String, int>(
  myString,
  (s) => s.length * 42,
);
```

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
Future<int> double(int value) {
  return runInIsolateWithArg(value, (v) => v * 2);
}
```

### Modes

| Mode | Behaviour |
|------|-----------|
| `IsolateRunMode.auto` | Background isolate when a `RootIsolateToken` is available, otherwise current isolate. |
| `IsolateRunMode.alwaysIsolate` | Always background isolate. |
| `IsolateRunMode.currentIsolate` | Always current isolate (useful for testing). |

---

## Usage: Persistent Worker

Use a persistent worker when you need many requests over time. The handler
**must be top-level or `static`**.

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

- `spawnWorker` is idempotent — safe to call multiple times while running.
- If startup is already in progress, other `spawnWorker` calls await the same startup.
- `requestWorker` auto-respawns the worker after dispose (if a handler was previously registered).
- Calling `spawnWorker` again with a different handler or options restarts the worker with the new configuration.
- `disposeWorker` must be called when the owner lifecycle ends.

### Payload contract

`requestWorker` payloads and worker results must be one of:

- `null`, `bool`, `num`, `String`
- `List` / `Map` (containing supported types, no circular references)
- `TransferableTypedData`
- `SendPort`

Custom classes are not accepted directly — convert to `Map` / `List` first.

---

## Flutter Lifecycle Example

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

---

## Rules for reliable usage

1. Keep heavy work inside the callback body.
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

For a complete app demonstrating all three APIs (static, instance, and persistent
worker), see the `example/` directory.
