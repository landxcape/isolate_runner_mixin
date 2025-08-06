import 'package:flutter/material.dart';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

// --- Example: A service that uses the mixin ---
class MyHeavyComputationService with IsolateRunnerMixin {
  Future<String> performHeavyTask(String input) async {
    // We'll pass a closure to runInIsolate.
    // This closure will be executed in the background isolate.
    return await runInIsolate(() async {
      // This code runs in the background isolate.
      // Simulate a CPU-intensive task.
      debugPrint('Isolate: Starting heavy computation for: "$input"');
      String result = '';
      for (int i = 0; i < 100000000; i++) {
        result = input + i.toString(); // Just some arbitrary computation
      }
      debugPrint('Isolate: Finished heavy computation.');
      return "Result for '$input': ${result.substring(result.length - 10)}";
    });
  }

  Future<String> performPluginTask(String input) async {
    // This example assumes you have a plugin that might block the UI
    // if called directly on the main thread. For demonstration,
    // we'll just use a Future.delayed, but imagine this is a plugin call.
    return await runInIsolate(() async {
      debugPrint('Isolate: Starting plugin-like task for: "$input"');
      // In a real scenario, this would be a call to a Flutter plugin:
      // e.g., await SomePlugin.doSomethingNative(input);
      await Future.delayed(Duration(seconds: 1));
      debugPrint('Isolate: Finished plugin-like task.');
      return "Plugin Task Done for: $input";
    });
  }
}

// --- Flutter UI ---
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Isolate Runner Example',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final MyHeavyComputationService _service = MyHeavyComputationService();
  String _computationResult = 'No computation yet.';
  String _pluginTaskResult = 'No plugin task yet.';
  bool _isComputing = false;
  bool _isPluginTaskRunning = false;

  Future<void> _startComputation() async {
    setState(() {
      _isComputing = true;
      _computationResult = 'Computing...';
    });
    try {
      final result = await _service.performHeavyTask('Example Data');
      setState(() {
        _computationResult = result;
      });
    } catch (e) {
      setState(() {
        _computationResult = 'Error: $e';
      });
    } finally {
      setState(() {
        _isComputing = false;
      });
    }
  }

  Future<void> _startPluginTask() async {
    setState(() {
      _isPluginTaskRunning = true;
      _pluginTaskResult = 'Running plugin task...';
    });
    try {
      final result = await _service.performPluginTask('Plugin Input');
      setState(() {
        _pluginTaskResult = result;
      });
    } catch (e) {
      setState(() {
        _pluginTaskResult = 'Error: $e';
      });
    } finally {
      setState(() {
        _isPluginTaskRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Isolate Runner Example')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              SizedBox(height: MediaQuery.sizeOf(context).height / 4),
              ElevatedButton(onPressed: _isComputing ? null : _startComputation, child: const Text('Start Heavy Computation')),
              const SizedBox(height: 10),
              _isComputing ? const CircularProgressIndicator() : Text(_computationResult, textAlign: TextAlign.center),
              const SizedBox(height: 30),
              ElevatedButton(onPressed: _isPluginTaskRunning ? null : _startPluginTask, child: const Text('Start Plugin-like Task')),
              const SizedBox(height: 10),
              _isPluginTaskRunning ? const CircularProgressIndicator() : Text(_pluginTaskResult, textAlign: TextAlign.center),
              const SizedBox(height: 30),
              const Text(
                'Try scrolling or interacting with the UI while tasks are running to see that the UI remains responsive.',
                textAlign: TextAlign.center,
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              SizedBox(height: MediaQuery.sizeOf(context).height * 0.6),
              const Text('Powered by Isolate Runner Mixin', style: TextStyle(color: Colors.blue, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}
