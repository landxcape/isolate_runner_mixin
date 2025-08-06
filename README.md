# isolate_runner_mixin

A Flutter-aware Dart mixin for easily running CPU-intensive tasks, including those that use Flutter plugins, in a background isolate.

## Why use this package?

Flutter applications run on a single thread, the UI thread. If you perform long-running or computationally intensive tasks directly on this thread, your UI can become unresponsive, leading to "jank" and a poor user experience. Dart's Isolates provide a way to run code concurrently in separate memory spaces, preventing UI blocking.

However, using raw dart:isolate APIs can be verbose, especially when dealing with Flutter plugins, which require specific initialization (BackgroundIsolateBinaryMessenger.ensureInitialized) within the background isolate.

This package provides a simple IsolateRunnerMixin that encapsulates this boilerplate, allowing you to easily offload any `FutureOr<T> Function()` to a background isolate.

## Key Features

**Simple API**: A single runInIsolate method.

**Flutter Plugin Compatible**: Automatically initializes BackgroundIsolateBinaryMessenger in the background isolate using the RootIsolateToken.

**UI Thread Protection**: Ensures heavy computations run off the main thread.

**Graceful Fallback**: Automatically runs tasks on the current thread if no Flutter binding is available (e.g., in pure Dart tests).

**Unique Mixin Design**: Integrates isolate functionality directly into your classes, providing a clean, object-oriented API that feels more natural than using top-level functions or helper classes.

## Installation

Add this to your pubspec.yaml file:

## dependencies

```yaml
  isolate_runner_mixin: <latest>
```

Then, run flutter pub get.

## Usage

## Apply the Mixin

Apply IsolateRunnerMixin to any class where you want to run tasks in a background isolate.

```dart
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';
import 'package:fast_rsa/fast_rsa.dart'; // Example plugin usage

class MyService with IsolateRunnerMixin {
  // Your service logic
  String _publicKey = '...'; // Example data

  Future<bool> verifyData(String data, String signature) async {
    // Use runInIsolate to offload the heavy work
    return await runInIsolate(() async {
      // This code runs in the background isolate
      await Future.delayed(const Duration(milliseconds: 100)); // Simulate work
      final isValid = await RSA.verifyPKCS1v15(signature, data, Hash.SHA256, _publicKey);
      return isValid;
    });
  }
}
```

## Top-Level/Static Functions for Heavy Work (Recommended)

While Isolate.run can implicitly capture variables from closures, it's generally safer and more explicit to pass all necessary data to a top-level or static function that performs the heavy work. This function will then be called from within the runInIsolate's closure.

```dart
// This must be a top-level function or a static method.
// It receives all its data via explicit arguments.
import 'package:fast_rsa/fast_rsa.dart';

Future<bool> _performVerification(String data, String signature, String publicKey) async {
  // This code runs in the background isolate
  await Future.delayed(const Duration(milliseconds: 100)); // Simulate work
  final isValid = await RSA.verifyPKCS1v15(signature, data, Hash.SHA256, publicKey);
  return isValid;
}

class MyService with IsolateRunnerMixin {
  String _publicKey = '...'; // Example data

  Future<bool> verifyData(String data, String signature) async {
    return await runInIsolate(() async {
      // Call the top-level function with explicit arguments
      return await _performVerification(data, signature,_publicKey);
    });
  }
}
```

## Example App

For a complete example, see the example/ directory in the package repository. The example demonstrates using the mixin to run both a CPU-intensive loop and a plugin-like task while keeping the UI responsive.

## Contributing

Feel free to open issues or pull requests on GitHub.

## License

This package is licensed under the MIT License. See the LICENSE file for details.
