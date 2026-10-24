# isolate_runner_mixin

A Flutter-aware mixin for offloading CPU-intensive tasks and managing persistent background workers with seamless Web and WebAssembly (WASM) fallback.

[![pub package](https://img.shields.io/pub/v/isolate_runner_mixin.svg)](https://pub.dev/packages/isolate_runner_mixin)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-flutter%20%7C%20android%20%7C%20ios%20%7C%20web%20%7C%20macos%20%7C%20linux%20%7C%20windows-blue)](https://pub.dev/packages/isolate_runner_mixin)

`isolate_runner_mixin` provides two core execution patterns for Flutter applications:
1. **One-Off Tasks (`runInIsolate`)**: Execute isolated computation with automatic `RootIsolateToken` propagation for Flutter platform plugins.
2. **Persistent Workers (`spawnWorker` + `requestWorker`)**: Long-lived background isolate with bi-directional message routing, payload validation, startup timeouts, and lifecycle management.

## Features

- **Background Plugin Support**: Automatically registers `BackgroundIsolateBinaryMessenger` so Flutter plugins work seamlessly inside background isolates.
- **Cross-Platform & WASM Ready**: On Native (Android, iOS, macOS, Windows, Linux), executes in dedicated multi-threaded OS isolates. On Web and WebAssembly (WASM), transparently falls back to cooperative event-loop scheduling with microtask yields, guaranteeing 100% API parity with zero platform compilation blockers.
- **Sequential Persistent Worker**: Spawn a worker once and dispatch multiple requests sequentially over dedicated send/receive ports.
- **Robust Failure Domain**: Centralized exception hierarchy (`IsolateWorkerException`) catching crashes, timeouts, circular payload references, and disposal aborts cleanly.
- **Memory Leak Protection**: Integrated debug-mode `Finalizer` tracking active worker isolates and warning when `disposeWorker()` is omitted in stateful lifecycles.

## Installation

Add via CLI:

```bash
flutter pub add isolate_runner_mixin
```

Or add to your `pubspec.yaml`:

```yaml
dependencies:
  isolate_runner_mixin: ^<latest>
```

---

## Quick Start

### 1. One-Off Tasks (`runInIsolate`)

Mix into any class, service, or widget state:

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

int _heavySum(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) total += i;
  return total;
}

class CalculationService with IsolateRunnerMixin {
  Future<int> computeTotal(int n) {
    return runInIsolate(() => _heavySum(n));
  }

  // Single-argument convenience:
  Future<int> computeWithArg(int n) {
    return runInIsolateWithArg(n, _heavySum);
  }
}
```

#### Execution Modes

| Mode | Behavior |
| :--- | :--- |
| `IsolateRunMode.auto` | Uses background isolate when a `RootIsolateToken` is available; otherwise falls back to current isolate. *(Default)* |
| `IsolateRunMode.alwaysIsolate` | Always spawns a background isolate. |
| `IsolateRunMode.currentIsolate` | Executes synchronously on the current isolate (ideal for test environments). |

---

### 2. Persistent Worker (`spawnWorker` & `requestWorker`)

Use a persistent worker when processing repeated requests over time. Requests are processed **sequentially** in FIFO order.

The handler must be a **top-level or `static` function**:

```dart
import 'dart:async';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

FutureOr<Object?> cryptoWorkerHandler(String command, Object? payload) async {
  switch (command) {
    case 'hash':
      final text = payload as String;
      // Perform CPU-intensive hashing...
      return text.hashCode.toString();
    case 'transform':
      final list = payload as List<Object?>;
      return list.map((e) => (e as int) * 2).toList();
  }
  throw UnsupportedError('Unknown command: $command');
}

class CryptoRepository with IsolateRunnerMixin {
  Future<void> init() async {
    await spawnWorker(
      handler: cryptoWorkerHandler,
      options: const SpawnWorkerOptions(
        maxPendingRequests: 1000,
        startupTimeout: Duration(seconds: 10),
      ),
    );
  }

  Future<String> hashText(String text) {
    return requestWorker<String>(
      command: 'hash',
      payload: text,
      timeout: const Duration(seconds: 5),
    );
  }

  Future<void> dispose() async {
    await disposeWorker();
  }
}
```

---

## Web & WebAssembly (WASM) Architecture

On Flutter Web and WebAssembly, `dart:isolate` primitives are unavailable. `isolate_runner_mixin` employs conditional compilation:

- **Native Targets**: Spawns true multi-threaded `dart:isolate` instances with `ReceivePort` and `SendPort` streams.
- **Web & WASM Targets**: Uses a cooperative event-loop worker that yields via `Future.delayed(Duration.zero)` and `scheduleMicrotask`, preventing main-thread UI jank while executing the identical `IsolateWorkerHandler` logic.
- **100% Parity**: Payload contract verification, exceptions (`IsolateWorkerRemoteException`, `IsolateWorkerPayloadException`), and disposal lifecycles behave identically across all platforms.

---

## Payload Contract

`requestWorker` payloads and return values must satisfy the isolate transport contract:
- `null`, `bool`, `num`, `String`
- `List` and `Map` containing recursively supported types (no circular references)
- `TransferableTypedData`
- `SendPort`

Circular references and unregistered complex objects are detected and rejected prior to dispatch.

---

## Exception Handling

All worker exceptions inherit from `IsolateWorkerException`:

```dart
try {
  final result = await service.requestWorker<String>(command: 'hash', payload: data);
} on IsolateWorkerRemoteException catch (e) {
  // Thrown if the handler threw inside the worker isolate:
  print('Command "${e.command}" failed: ${e.remoteError}');
  print(e.remoteStackTrace);
} on IsolateWorkerDisposedException catch (_) {
  // Thrown if disposeWorker() was called while request was pending.
} on IsolateWorkerQueueOverflowException catch (_) {
  // Thrown if pending requests exceed SpawnWorkerOptions.maxPendingRequests.
} on IsolateWorkerTerminatedException catch (e) {
  // Thrown if worker isolate terminated unexpectedly.
} on TimeoutException catch (_) {
  // Thrown if per-request deadline elapsed.
}
```
