# Logmonitor Flutter SDK

<p align="center">
  <img src="https://logmonitor.io/logo.png" alt="Logmonitor" height="80" />
</p>

<p align="center">
  <a href="https://pub.dev/packages/logmonitor_flutter"><img src="https://img.shields.io/pub/v/logmonitor_flutter.svg" alt="pub package" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT" /></a>
</p>

The official Flutter SDK for [Logmonitor.io](https://logmonitor.io).

Stream your production logs in real-time — just like your local console. This package integrates with `package:logging` and optionally captures all `print()` calls, `debugPrint()` output, Flutter framework errors, and unhandled async exceptions.

## Features

| Feature | Description |
|---------|-------------|
| **Structured logging** | Captures all `package:logging` records automatically |
| **Print interception** | Captures `print()` and `debugPrint()` calls — including from third-party libraries (opt-in) |
| **Error capture** | Catches Flutter framework errors and unhandled async exceptions (opt-in) |
| **Smart batching** | Buffers logs and sends them in efficient batches to minimize network usage |
| **Debug / Release modes** | Prints to console in debug mode; sends to server in release mode |
| **User association** | Tag logs with a user ID for easy filtering on your dashboard |
| **Zero overhead in debug** | No network calls are made in debug mode |

## Platform Support

| Platform | Supported |
|----------|:---------:|
| Android  | ✅ |
| iOS      | ✅ |
| Web      | ✅ |
| macOS    | ✅ |
| Windows  | ✅ |
| Linux    | ✅ |

## Getting Started

### 1. Install

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  logmonitor_flutter: ^0.2.0
  logging: ^1.3.0
```

Then run:

```sh
flutter pub get
```

### 2. Initialize

Call `Logmonitor.init()` early in your `main()`, **after** `WidgetsFlutterBinding.ensureInitialized()`:

```dart
import 'package:flutter/material.dart';
import 'package:logmonitor_flutter/logmonitor_flutter.dart';
import 'package:logging/logging.dart';

final log = Logger('MyApp');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Logmonitor.init(apiKey: 'YOUR_LOGMONITOR_API_KEY');

  log.info('Application started');
  runApp(const MyApp());
}
```

### 3. Log

Use the standard `logging` package anywhere in your app — Logmonitor forwards all records automatically:

```dart
import 'package:logging/logging.dart';

final log = Logger('PaymentScreen');

void onCheckout() {
  log.info('Checkout initiated');
  log.warning('Payment gateway returned a slow response');
  log.severe('Payment failed', error, stackTrace);
}
```

## Automatic Print & Error Capture

Enable `captureAllPrints` and `captureFlutterErrors` to capture everything — not just `Logger` output. Use `Logmonitor.runGuarded()` instead of `runApp()` to wrap your app in a guarded zone:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Logmonitor.init(
    apiKey: 'YOUR_LOGMONITOR_API_KEY',
    captureAllPrints: true,
    captureFlutterErrors: true,
  );
  Logmonitor.runGuarded(const MyApp());
}
```

### What gets captured

| Source | Captured by | Flag required |
|--------|------------|---------------|
| `Logger` records (`log.info(...)`) | `Logger.root.onRecord` | None (always on) |
| `print()` calls | Zone-based interception | `captureAllPrints` + `runGuarded()` |
| `debugPrint()` calls | `debugPrint` override | `captureAllPrints` |
| Framework errors (build/layout/paint) | `FlutterError.onError` | `captureFlutterErrors` |
| Unhandled async exceptions | `PlatformDispatcher.instance.onError` | `captureFlutterErrors` |
| Uncaught zone errors | `runZonedGuarded` | `runGuarded()` |

### Advanced zone composition

For advanced use cases where you need to compose your own zone (e.g., integrating with Sentry or Crashlytics), the SDK exposes public getters:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:logmonitor_flutter/logmonitor_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Logmonitor.init(
    apiKey: 'YOUR_LOGMONITOR_API_KEY',
    captureAllPrints: true,
  );

  runZonedGuarded(
    () => runApp(const MyApp()),
    Logmonitor.onError,
    zoneSpecification: Logmonitor.zoneSpec,
  );
}
```

## User Association

Tag all subsequent log entries with a user ID for easy filtering:

```dart
// After login
Logmonitor.setUser(userId: 'user-jane-doe-123');

// After logout
Logmonitor.clearUser();
```

## Lifecycle Management

Call `Logmonitor.dispose()` when the app shuts down to flush any remaining buffered logs:

```dart
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Best-effort flush — don't await, the OS may kill the app.
      Logmonitor.dispose();
    }
  }
}
```

## How It Works

```
┌─────────────────────────────────────────────────────┐
│                   Your Flutter App                  │
│                                                     │
│  Logger.info()  print()  debugPrint()  throw Error  │
│       │            │          │             │        │
└───────┼────────────┼──────────┼─────────────┼───────┘
        │            │          │             │
        ▼            ▼          ▼             ▼
┌─────────────────────────────────────────────────────┐
│               Logmonitor Flutter SDK                │
│                                                     │
│  Logger.root   Zone print   debugPrint   Flutter    │
│  .onRecord     handler      override     Error +    │
│                                          Platform   │
│                                          Dispatcher │
│                         │                           │
│                    ┌────▼────┐                      │
│                    │  Buffer │                      │
│                    │ (batch) │                      │
│                    └────┬────┘                      │
│                         │                           │
│              ┌──────────▼──────────┐                │
│              │  Debug?  │ Release? │                │
│              │ Console  │  HTTP    │                │
│              │  only    │  POST    │                │
│              └──────────┴──────────┘                │
└─────────────────────────────────────────────────────┘
                          │
                          ▼
               ┌─────────────────────┐
               │  Logmonitor.io API  │
               │  → Your Dashboard   │
               └─────────────────────┘
```

## API Reference

| Method | Description |
|--------|-------------|
| `Logmonitor.init({apiKey, captureAllPrints, captureFlutterErrors})` | Initialize the SDK. Call once at startup. |
| `Logmonitor.runGuarded(Widget app)` | Run your app inside a guarded zone with print/error capture. |
| `Logmonitor.setUser({userId})` | Associate subsequent logs with a user ID. |
| `Logmonitor.clearUser()` | Remove the current user association. |
| `Logmonitor.dispose()` | Flush remaining logs and release all resources. |
| `Logmonitor.onError` | Zone error handler getter for advanced composition. |
| `Logmonitor.zoneSpec` | Zone specification getter for advanced composition. |

See the [API documentation](https://pub.dev/documentation/logmonitor_flutter/latest/) for full details.

## Debug vs. Release Behavior

| | Debug mode | Release mode |
|---|---|---|
| Logger records | Printed to console | Batched and sent to server |
| print() / debugPrint() | Printed to console (if capture enabled) | Batched and sent to server |
| Flutter errors | Printed to console (if capture enabled) | Batched and sent to server |
| Network calls | None | Batched POST every 15s or at 20 entries |

## Requirements

- Dart SDK `^3.10.0`
- Flutter `>=3.29.0`

## License

MIT -- see [LICENSE](LICENSE) for details.
