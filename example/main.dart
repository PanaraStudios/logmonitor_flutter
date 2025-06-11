import 'package:flutter/material.dart';
import 'package:logmonitor_flutter/logmonitor_flutter.dart';
import 'package:logging/logging.dart';

final log = Logger('MyApp');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Logmonitor.init(apiKey: "YOUR_LOGMONITOR_API_KEY");
  log.info("Application starting up.");
  runApp(const MyApp());
}

// Make your main app widget stateful to listen to the app lifecycle.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

// Use the WidgetsBindingObserver mixin to get lifecycle events.
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // Register the observer
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // IMPORTANT: Remove the observer
    WidgetsBinding.instance.removeObserver(this);
    // Call Logmonitor.dispose() here
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
      // We don't await this because the app might be killed by the OS.
      // This is a best-effort "fire and forget".
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
