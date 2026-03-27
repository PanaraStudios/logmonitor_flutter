## 0.2.0

-   Added automatic `print()` interception via zone-based capture (`captureAllPrints` flag).
-   Added `debugPrint` override to capture Flutter framework diagnostics.
-   Added `FlutterError.onError` and `PlatformDispatcher.instance.onError` hooks (`captureFlutterErrors` flag).
-   Added `Logmonitor.runGuarded()` method to wrap `runApp()` in a guarded zone.
-   Exposed `Logmonitor.onError` and `Logmonitor.zoneSpec` for advanced zone composition.
-   All new features are opt-in and fully backward-compatible.

## 0.1.2

-   Fixed API endpoint to use the correct production URL.
-   Fixed `logUserId` to send `null` instead of empty string when no user is set.
-   Added `Level.SHOUT` mapping to `'error'` log level.

## 0.1.1

-   Added error and stack trace support — `LogRecord.error` and `LogRecord.stackTrace` are now included in the log payload.

## 0.1.0

-   Updated Dart SDK constraint to `^3.10.0` and Flutter to `>=3.29.0`.
-   Updated `http` to `^1.6.0`, `package_info_plus` to `^9.0.0`, `flutter_lints` to `^6.0.0`.
-   Added comprehensive documentation comments (library-level and API-level dartdoc).
-   Adopted Dart 3.10 null-aware map element syntax.

## 0.0.1

-   Initial release of the Logmonitor Flutter SDK.
-   Supports log batching and automatic mode switching (debug vs. release).
-   Integrates with `package:logging`.
-   Includes `setUser` and `clearUser` for per-user log association.
