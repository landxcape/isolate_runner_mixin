/// A Flutter-aware mixin for running CPU-intensive tasks and persistent background
/// workers off the main UI isolate with cooperative Web and WebAssembly (WASM) fallback.
library;

export 'src/isolate_models.dart';
export 'src/isolate_runner_web.dart'
    if (dart.library.isolate) 'src/isolate_runner_native.dart';
