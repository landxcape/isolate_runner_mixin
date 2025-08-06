import 'dart:async';
import 'dart:isolate';

import 'package:flutter/services.dart'; // Required for BackgroundIsolateBinaryMessenger

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
  // CRITICAL: Initialize the BinaryMessenger here, inside the isolate.
  // This allows Flutter plugins to communicate with the native platform.
  if (task.token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(task.token!);
  }

  // Now, safely execute the task function provided by the main isolate.
  // The result of this future is automatically returned by Isolate.run.
  return await task.task();
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
  /// Runs the given [fn] in a background isolate.
  ///
  /// This method handles the boilerplate of spawning an isolate,
  /// initializing the `BackgroundIsolateBinaryMessenger` (if a Flutter
  /// binding is available), executing the provided function [fn], and
  /// returning its result.
  ///
  /// The [fn] should encapsulate all the CPU-intensive or plugin-dependent
  /// work. It will be executed in a separate isolate.
  ///
  /// If `RootIsolateToken.instance` is null (e.g., in pure Dart environments
  /// like command-line apps or unit tests without a Flutter binding), the
  /// [fn] will be executed on the current thread.
  ///
  /// Throws any errors that occur during the execution of [fn] or isolate setup.
  Future<T> runInIsolate<T>(FutureOr<T> Function() fn) async {
    final token = RootIsolateToken.instance;

    // If no Flutter binding (e.g., in pure Dart tests), run on current thread.
    // This provides a graceful fallback for non-Flutter environments.
    if (token == null) {
      return await fn.call();
    }

    // Create a task object to hold the token and the function.
    // This object is then sent across the isolate boundary.
    final task = _IsolateTask<T>(token, fn);

    // Spawn a new isolate, run the [_isolateEntryPoint] with the task,
    // and await the result. This operation is non-blocking on the current thread.
    return await Isolate.run(() => _isolateEntryPoint(task));
  }
}
