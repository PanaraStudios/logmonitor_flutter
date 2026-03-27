/// Example app demonstrating the Logmonitor Flutter SDK.
///
/// This example shows how to:
/// - Initialize Logmonitor with print and error capture enabled.
/// - Use [Logmonitor.runGuarded] to wrap [runApp] in a guarded zone.
/// - Properly flush logs when the app is paused or detached.
/// - Log messages using `package:logging`.
library;

import 'package:flutter/material.dart';
import 'package:logmonitor_flutter/logmonitor_flutter.dart';
import 'package:logging/logging.dart';

/// A [Logger] instance scoped to this app.
///
/// Create one per file or feature area for easy filtering
/// on the Logmonitor dashboard.
final log = Logger('MyApp');

/// Entry point for the example app.
///
/// Initializes the SDK with all capture flags enabled, then
/// launches the app inside a guarded zone via [Logmonitor.runGuarded].
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Logmonitor.init(
    apiKey: "YOUR_LOGMONITOR_API_KEY",
    captureAllPrints: true,
    captureFlutterErrors: true,
  );
  log.info("Application starting up.");
  Logmonitor.runGuarded(const MyApp());
}

/// Root widget of the example app.
///
/// Uses [WidgetsBindingObserver] to detect lifecycle changes and
/// flush buffered logs before the OS kills the process.
class MyApp extends StatefulWidget {
  /// Creates the example app widget.
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Logmonitor.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // On some platforms, `dispose` isn't always called.
    // Flushing logs when the app is paused or detached is a good safety net.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      log.info("App is closing or pausing, flushing logs...");
      // Best-effort "fire and forget" — the OS may kill the app at any time.
      Logmonitor.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Logmonitor Example')),
        body: Center(
          child: ElevatedButton(
            onPressed: () {
              log.warning("Button was pressed!");
            },
            child: const Text('Trigger a Warning'),
          ),
        ),
      ),
    );
  }
}
