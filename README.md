# Logmonitor Flutter SDK

The official Flutter SDK for [Logmonitor.io](https://logmonitor.io).

Logmonitor streams your production logs in real-time, so you can `console.log` your production app and fix bugs faster. This package integrates with the standard `package:logging` to automatically capture logs in release mode while printing them locally during development.

## Features

-   Automatically captures logs from `package:logging`.
-   Prints logs to console in debug mode, sends to API in release mode.
-   Efficiently batches logs to minimize network traffic.
-   Cleans up resources automatically using the app lifecycle.

## Getting Started

### 1. Add Dependency

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  logmonitor_flutter: ^0.1.0
  logging: ^1.3.0
```

### 2. Initialize Logmonitor

In your `main.dart`, initialize Logmonitor before `runApp()`.

```dart
import 'package:flutter/material.dart';
import 'package:logmonitor_flutter/logmonitor_flutter.dart';
import 'package:logging/logging.dart';

final log = Logger('MyApp');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Logmonitor once.
  await Logmonitor.init(apiKey: "YOUR_LOGMONITOR_API_KEY");

  log.info("Application is starting up.");
  runApp(const MyApp());
}
```

### 3. Usage Example

Use the standard `logging` package to create logs. Logmonitor will handle the rest.

```dart
// In any file
import 'package:logging/logging.dart';
final log = Logger('MyScreen');

// ... inside a widget method
onPressed: () {
  log.warning("User performed a potentially risky action.");
}
```

### Associating Logs with a User

To filter logs by a specific user on your Logmonitor dashboard:

```dart
// When a user logs in
Logmonitor.setUser(userId: "user-jane-doe-123");
log.info("User has been identified.");

// When they log out
Logmonitor.clearUser();
```

---