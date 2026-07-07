import 'dart:async';

import 'package:flutter/material.dart';
import 'package:isolate_runner_mixin/isolate_runner_mixin.dart';

// ---------------------------------------------------------------------------
// Top-level helpers (must be top-level or static for isolate usage)
// ---------------------------------------------------------------------------

int _sumUpTo(int n) {
  var total = 0;
  for (var i = 0; i < n; i++) {
    total += i;
  }
  return total;
}

// Worker handler for the persistent worker demo.
FutureOr<Object?> _workerHandler(String command, Object? payload) async {
  switch (command) {
    case 'sum':
      final n = payload as int;
      return _sumUpTo(n);
    case 'echo':
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return payload;
  }
  throw UnsupportedError('Unknown command: $command');
}

// ---------------------------------------------------------------------------
// Service using the mixin (instance API)
// ---------------------------------------------------------------------------

class ComputeService with IsolateRunnerMixin {
  Future<int> computeSum(int n) {
    // Instance method — background isolate via the mixin.
    return runInIsolate(() => _sumUpTo(n));
  }

  Future<void> dispose() async {
    await disposeWorker();
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Isolate Runner Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  final _service = ComputeService();

  String _instanceResult = '—';
  String _workerResult = '—';

  bool _instanceRunning = false;
  bool _workerRunning = false;

  // ── Instance API demo ──────────────────────────────────────────────────────

  Future<void> _runInstance() async {
    setState(() {
      _instanceRunning = true;
      _instanceResult = 'Computing…';
    });
    try {
      final result = await _service.computeSum(50000000);
      setState(() => _instanceResult = 'sum(50M) = $result');
    } catch (e) {
      setState(() => _instanceResult = 'Error: $e');
    } finally {
      setState(() => _instanceRunning = false);
    }
  }

  // ── Persistent worker demo ─────────────────────────────────────────────────

  Future<void> _runWorker() async {
    setState(() {
      _workerRunning = true;
      _workerResult = 'Spawning worker…';
    });
    try {
      await _service.spawnWorker(handler: _workerHandler);
      setState(() => _workerResult = 'Worker running — sending requests…');

      final results = await Future.wait<int>([
        _service.requestWorker<int>(command: 'sum', payload: 10000000),
        _service.requestWorker<int>(command: 'sum', payload: 20000000),
        _service.requestWorker<int>(command: 'sum', payload: 30000000),
      ]);

      setState(
        () => _workerResult =
            'sum(10M)=${results[0]}\n'
            'sum(20M)=${results[1]}\n'
            'sum(30M)=${results[2]}',
      );
    } catch (e) {
      setState(() => _workerResult = 'Error: $e');
    } finally {
      setState(() => _workerRunning = false);
    }
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('isolate_runner_mixin'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _DemoCard(
            title: 'Instance API',
            subtitle: 'class Service with IsolateRunnerMixin',
            code: 'await runInIsolate(() => _sumUpTo(50000000));',
            result: _instanceResult,
            running: _instanceRunning,
            onRun: _runInstance,
          ),
          const SizedBox(height: 16),
          _DemoCard(
            title: 'Persistent Worker',
            subtitle: 'spawnWorker + requestWorker (3 concurrent requests)',
            code:
                'await spawnWorker(handler: _workerHandler);\n'
                'await Future.wait([requestWorker(...), requestWorker(...), ...]);',
            result: _workerResult,
            running: _workerRunning,
            onRun: _runWorker,
          ),
          const SizedBox(height: 32),
          const Text(
            'The UI stays responsive during all operations — scroll or tap '
            'while tasks are running to verify.',
            textAlign: TextAlign.center,
            style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.title,
    required this.subtitle,
    required this.code,
    required this.result,
    required this.running,
    required this.onRun,
  });

  final String title;
  final String subtitle;
  final String code;
  final String result;
  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: running ? null : onRun,
                  child: Text(running ? 'Running…' : 'Run'),
                ),
                const SizedBox(width: 16),
                if (running)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Expanded(
                    child: Text(
                      result,
                      style: TextStyle(
                        color: cs.primary,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
