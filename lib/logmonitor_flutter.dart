/// The official Flutter SDK for [Logmonitor.io](https://logmonitor.io).
///
/// This library provides a simple way to capture and forward your
/// application's logs to the Logmonitor service, allowing you to view
/// production logs in real-time — just like your local console.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:logmonitor_flutter/logmonitor_flutter.dart';
/// import 'package:logging/logging.dart';
///
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Logmonitor.init(
///     apiKey: 'YOUR_API_KEY',
///     captureAllPrints: true,
///     captureFlutterErrors: true,
///   );
///
///   final log = Logger('MyApp');
///   log.info('Application started');
///
///   Logmonitor.runGuarded(const MyApp());
/// }
/// ```
///
/// ## How It Works
///
/// The SDK integrates with Dart's built-in [Logger] from `package:logging`.
/// Once initialized, it automatically captures all log records and batches
/// them for efficient delivery to the Logmonitor backend.
///
/// With `captureAllPrints: true`, the SDK also intercepts every `print()`
/// and `debugPrint()` call — including output from third-party libraries —
/// using Dart's zone system and Flutter's settable [debugPrint] variable.
///
/// With `captureFlutterErrors: true`, framework errors (build, layout,
/// paint) and unhandled async exceptions are automatically captured via
/// [FlutterError.onError] and [PlatformDispatcher.instance.onError].
///
/// In **debug mode** (`kDebugMode`), logs are printed to the console via
/// [debugPrint] and are **not** sent to the server.
///
/// In **release mode**, logs are buffered and sent in batches — either when
/// the buffer reaches [Logmonitor._maxBatchSize] entries or every
/// [Logmonitor._batchPeriod], whichever comes first.
///
/// ## User Association
///
/// You can associate logs with a specific user by calling
/// [Logmonitor.setUser], and clear it with [Logmonitor.clearUser]:
///
/// ```dart
/// Logmonitor.setUser(userId: 'user_123');
/// // ... logs are now tagged with this user ID
/// Logmonitor.clearUser();
/// ```
///
/// ## Cleanup
///
/// Call [Logmonitor.dispose] when the app is shutting down to flush any
/// remaining logs and release resources.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Widget, runApp;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:logging/logging.dart';

/// The main entry point for the Logmonitor Flutter SDK.
///
/// [Logmonitor] is a singleton that captures log records from Dart's
/// [Logger] and sends them to the Logmonitor backend in batches.
///
/// Use [init] to initialize the SDK with your API key, then use
/// `package:logging` as usual — all log records will be forwarded
/// automatically.
///
/// {@template logmonitor_lifecycle}
/// ### Lifecycle
///
/// 1. Call [Logmonitor.init] early in your app's startup (after
///    `WidgetsFlutterBinding.ensureInitialized()`). Pass `captureAllPrints`
///    and/or `captureFlutterErrors` to enable automatic capture.
/// 2. Call [Logmonitor.runGuarded] instead of `runApp()` if any capture
///    flags are enabled.
/// 3. Optionally call [setUser] / [clearUser] to tag logs with a user ID.
/// 4. Call [dispose] when the app is closing to flush remaining logs and
///    restore all overridden hooks.
/// {@endtemplate}
class Logmonitor {
  // --- Singleton Setup ---
  static final Logmonitor _instance = Logmonitor._internal();

  /// Returns the singleton [Logmonitor] instance.
  ///
  /// You typically don't need to use this directly — prefer the static
  /// methods [init], [setUser], [clearUser], and [dispose].
  factory Logmonitor() => _instance;

  Logmonitor._internal();

  // --- Private State ---
  static const String _endpoint =
      "https://api.logmonitor.io/api/v1/logs";
  String? _apiKey;
  String? _bundleId;
  String? _logUserId;

  final List<Map<String, dynamic>> _logBuffer = [];
  Timer? _batchTimer;
  StreamSubscription<LogRecord>? _logSubscription;

  // --- Capture Configuration ---
  bool _captureAllPrints = false;
  bool _captureFlutterErrors = false;

  // --- Re-entry Guards ---
  bool _isInternalLog = false;
  bool _isDebugPrintOverride = false;

  // --- Stored Originals (restored on dispose) ---
  DebugPrintCallback? _originalDebugPrint;
  FlutterExceptionHandler? _originalFlutterErrorHandler;
  bool Function(Object, StackTrace)? _originalPlatformErrorHandler;

  /// The maximum number of log entries to buffer before sending a batch.
  static const int _maxBatchSize = 20;

  /// The interval at which buffered logs are sent, regardless of buffer size.
  static const Duration _batchPeriod = Duration(seconds: 15);

  /// Initializes the Logmonitor SDK and begins capturing log records.
  ///
  /// Must be called once before any logs can be forwarded to the Logmonitor
  /// backend. Typically called early in `main()` after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// The [apiKey] is your project's API key from
  /// [logmonitor.io](https://logmonitor.io).
  ///
  /// Set [captureAllPrints] to `true` to automatically capture all
  /// `print()` and `debugPrint()` calls. When enabled, use
  /// [Logmonitor.runGuarded] instead of `runApp()` to activate zone-based
  /// print interception.
  ///
  /// Set [captureFlutterErrors] to `true` to install hooks on
  /// [FlutterError.onError] and [PlatformDispatcher.instance.onError],
  /// capturing framework errors and unhandled async exceptions.
  ///
  /// In **debug mode**, logs are only printed to the console and are not
  /// sent to the server. In **release mode**, logs are batched and sent
  /// automatically.
  ///
  /// Calling this method more than once has no effect.
  ///
  /// ```dart
  /// await Logmonitor.init(
  ///   apiKey: 'YOUR_API_KEY',
  ///   captureAllPrints: true,
  ///   captureFlutterErrors: true,
  /// );
  /// Logmonitor.runGuarded(const MyApp());
  /// ```
  static Future<void> init({
    required String apiKey,
    bool captureAllPrints = false,
    bool captureFlutterErrors = false,
  }) async {
    if (_instance._apiKey != null) {
      _instance._internalDebugPrint("Logmonitor is already initialized.");
      return;
    }
    _instance._apiKey = apiKey;
    _instance._captureAllPrints = captureAllPrints;
    _instance._captureFlutterErrors = captureFlutterErrors;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _instance._bundleId = packageInfo.packageName;
    } catch (e) {
      _instance._internalDebugPrint("Logmonitor: Could not get package info. $e");
    }

    Logger.root.level = Level.ALL;

    _instance._logSubscription = Logger.root.onRecord.listen((
      LogRecord record,
    ) {
      if (kDebugMode) {
        _instance._internalDebugPrint(
          '[${record.level.name}] ${record.time}: ${record.loggerName}: ${record.message}',
        );
      } else {
        _instance._addLog(record);
      }
    });

    if (!kDebugMode) {
      _instance._startBatchTimer();
    }

    if (captureAllPrints) {
      _instance._overrideDebugPrint();
    }
    if (captureFlutterErrors) {
      _instance._installFlutterErrorHooks();
    }
  }

  /// Associates all subsequent log entries with the given [userId].
  ///
  /// This is useful for filtering logs by user in the Logmonitor dashboard.
  /// The user ID is included in every log entry until [clearUser] is called.
  ///
  /// ```dart
  /// Logmonitor.setUser(userId: 'user_123');
  /// ```
  static void setUser({required String userId}) {
    _instance._logUserId = userId;
  }

  /// Removes the current user association from subsequent log entries.
  ///
  /// After calling this method, log entries will no longer include a user ID.
  ///
  /// ```dart
  /// Logmonitor.clearUser();
  /// ```
  static void clearUser() {
    _instance._logUserId = null;
  }

  /// Runs [app] inside a guarded zone that captures all `print()` calls
  /// and unhandled errors, then calls Flutter's [runApp].
  ///
  /// Call this **instead of** `runApp()` when [captureAllPrints] or
  /// [captureFlutterErrors] was set to `true` during [init].
  ///
  /// If neither capture flag is enabled, this method simply delegates
  /// to [runApp] with no wrapping.
  ///
  /// ```dart
  /// await Logmonitor.init(
  ///   apiKey: 'YOUR_API_KEY',
  ///   captureAllPrints: true,
  ///   captureFlutterErrors: true,
  /// );
  /// Logmonitor.runGuarded(const MyApp());
  /// ```
  static void runGuarded(Widget app) {
    if (!_instance._captureAllPrints && !_instance._captureFlutterErrors) {
      runApp(app);
      return;
    }

    runZonedGuarded(
      () => runApp(app),
      (Object error, StackTrace stack) {
        if (_instance._apiKey != null && !kDebugMode) {
          _instance._addRawLog(
            level: 'error',
            message: error.toString(),
            payload: {
              'source': 'runZonedGuarded',
              'stackTrace': stack.toString(),
            },
          );
        }
        if (kDebugMode) {
          _instance._internalDebugPrint(
            'Logmonitor caught unhandled error: $error\n$stack',
          );
        }
      },
      zoneSpecification: _instance._captureAllPrints
          ? ZoneSpecification(
              print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
                // Always forward to console (preserve normal behavior).
                parent.print(zone, line);

                // Skip if this print originated from our debugPrint override
                // (prevents double-capture since debugPrint calls print).
                if (_instance._isDebugPrintOverride) return;

                // Skip the SDK's own internal logging.
                if (_instance._isInternalLog) return;

                if (!kDebugMode && _instance._apiKey != null) {
                  _instance._addRawLog(level: 'log', message: line);
                }
              },
            )
          : null,
    );
  }

  /// The zone error handler for use with [runZonedGuarded].
  ///
  /// Advanced users can use this to compose their own zone setup instead
  /// of using [runGuarded]:
  ///
  /// ```dart
  /// runZonedGuarded(
  ///   () => runApp(const MyApp()),
  ///   Logmonitor.onError,
  ///   zoneSpecification: Logmonitor.zoneSpec,
  /// );
  /// ```
  static void Function(Object, StackTrace) get onError =>
      (Object error, StackTrace stack) {
        if (_instance._apiKey != null && !kDebugMode) {
          _instance._addRawLog(
            level: 'error',
            message: error.toString(),
            payload: {
              'source': 'runZonedGuarded',
              'stackTrace': stack.toString(),
            },
          );
        }
      };

  /// The [ZoneSpecification] that intercepts `print()` calls.
  ///
  /// Returns `null` if [captureAllPrints] was not enabled during [init].
  ///
  /// See [onError] for a full advanced-usage example.
  static ZoneSpecification? get zoneSpec {
    if (!_instance._captureAllPrints) return null;
    return ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        parent.print(zone, line);
        if (_instance._isDebugPrintOverride) return;
        if (_instance._isInternalLog) return;
        if (!kDebugMode && _instance._apiKey != null) {
          _instance._addRawLog(level: 'log', message: line);
        }
      },
    );
  }

  /// Disposes of the Logmonitor SDK, flushing any buffered logs and
  /// releasing all resources.
  ///
  /// This method:
  /// 1. Stops listening for new log records.
  /// 2. Cancels the periodic batch timer.
  /// 3. Sends any remaining buffered logs to the server.
  /// 4. Resets all internal state.
  ///
  /// Should be called when the app is shutting down — for example, in your
  /// root widget's `dispose()` method or in response to an
  /// [AppLifecycleState.detached] event.
  ///
  /// After calling this method, [init] can be called again to reinitialize.
  static Future<void> dispose() async {
    if (_instance._apiKey == null) return;

    _instance._internalDebugPrint("Disposing Logmonitor...");

    await _instance._logSubscription?.cancel();
    _instance._logSubscription = null;

    _instance._batchTimer?.cancel();
    _instance._batchTimer = null;

    await _instance._sendLogs();

    // Restore original debugPrint.
    if (_instance._originalDebugPrint != null) {
      debugPrint = _instance._originalDebugPrint!;
      _instance._originalDebugPrint = null;
    }

    // Restore original FlutterError.onError.
    if (_instance._originalFlutterErrorHandler != null) {
      FlutterError.onError = _instance._originalFlutterErrorHandler;
      _instance._originalFlutterErrorHandler = null;
    }

    // Restore original PlatformDispatcher.instance.onError.
    if (_instance._originalPlatformErrorHandler != null) {
      PlatformDispatcher.instance.onError =
          _instance._originalPlatformErrorHandler!;
      _instance._originalPlatformErrorHandler = null;
    }

    _instance._captureAllPrints = false;
    _instance._captureFlutterErrors = false;
    _instance._isInternalLog = false;
    _instance._isDebugPrintOverride = false;

    _instance._apiKey = null;
    _instance._logUserId = null;
    _instance._logBuffer.clear();

    _instance._internalDebugPrint("Logmonitor disposed and shut down.");
  }

  // --- Private Helper Methods ---

  /// Calls [debugPrint] while suppressing re-capture by the override.
  ///
  /// All internal SDK logging must use this method instead of calling
  /// [debugPrint] directly to avoid infinite loops when print capture
  /// is enabled.
  void _internalDebugPrint(String message) {
    _isInternalLog = true;
    debugPrint(message);
    _isInternalLog = false;
  }

  /// Overrides [debugPrint] to capture its output.
  ///
  /// The original [debugPrint] is preserved and called for every message
  /// so console output is unchanged. In release mode, messages are also
  /// forwarded to the log buffer via [_addRawLog].
  void _overrideDebugPrint() {
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // Set guard so the zone print handler skips the underlying print()
      // call that debugPrint makes internally — prevents double-capture.
      _isDebugPrintOverride = true;
      _originalDebugPrint!(message, wrapWidth: wrapWidth);
      _isDebugPrintOverride = false;

      // Do not capture the SDK's own internal logging.
      if (_isInternalLog) return;

      if (!kDebugMode && _apiKey != null) {
        _addRawLog(level: 'log', message: message ?? '');
      }
    };
  }

  /// Installs hooks on [FlutterError.onError] and
  /// [PlatformDispatcher.instance.onError] to capture framework errors
  /// and unhandled async exceptions.
  ///
  /// Previous handlers are preserved and called first so existing crash
  /// reporters (e.g. Sentry, Crashlytics) continue to work.
  void _installFlutterErrorHooks() {
    // --- Synchronous framework errors (build, layout, paint) ---
    _originalFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Call original handler first (prints red error in debug mode).
      _originalFlutterErrorHandler?.call(details);

      if (_apiKey != null && !kDebugMode) {
        _addRawLog(
          level: 'error',
          message: details.exceptionAsString(),
          payload: {
            'source': 'FlutterError.onError',
            'library': details.library ?? 'unknown',
            if (details.stack != null)
              'stackTrace': details.stack.toString(),
            if (details.context != null)
              'context': details.context.toString(),
          },
        );
      }
    };

    // --- Asynchronous unhandled errors ---
    _originalPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      if (_apiKey != null && !kDebugMode) {
        _addRawLog(
          level: 'error',
          message: error.toString(),
          payload: {
            'source': 'PlatformDispatcher.onError',
            'stackTrace': stack.toString(),
          },
        );
      }
      // Delegate to original handler. Return false if none exists to let
      // the error propagate (preserves default crash reporting behavior).
      return _originalPlatformErrorHandler?.call(error, stack) ?? false;
    };
  }

  /// Adds a [LogRecord] to the internal buffer and triggers a send if the
  /// buffer has reached [_maxBatchSize].
  ///
  /// The log entry's `payload` is a structured map that may contain:
  /// - `data` — the [LogRecord.object], if provided.
  /// - `error` — the string representation of [LogRecord.error], if present.
  /// - `stackTrace` — the full [LogRecord.stackTrace] string, if present.
  ///
  /// If none of these fields are set, `payload` is `null`.
  void _addLog(LogRecord record) {
    final payload = <String, dynamic>{
      if (record.object != null) 'data': record.object,
      if (record.error != null) 'error': record.error.toString(),
      if (record.stackTrace != null) 'stackTrace': record.stackTrace.toString(),
    };
    final logData = {
      'level': _mapLogLevel(record.level),
      'message': record.message,
      'clientTimestamp': record.time.millisecondsSinceEpoch,
      'logUserId': _logUserId,
      'payload': payload.isNotEmpty ? payload : null,
    };
    _logBuffer.add(logData);
    if (_logBuffer.length >= _maxBatchSize) {
      _sendLogs();
    }
  }

  /// Adds a raw log entry directly to the buffer.
  ///
  /// Unlike [_addLog], which accepts a [LogRecord], this method accepts
  /// raw strings. It is used by the print interception zone handler,
  /// the [debugPrint] override, and the Flutter error hooks.
  void _addRawLog({
    required String level,
    required String message,
    Map<String, dynamic>? payload,
  }) {
    final logData = {
      'level': level,
      'message': message,
      'clientTimestamp': DateTime.now().millisecondsSinceEpoch,
      'logUserId': _logUserId,
      'payload': payload,
    };
    _logBuffer.add(logData);
    if (_logBuffer.length >= _maxBatchSize) {
      _sendLogs();
    }
  }

  /// Maps a Dart [Level] to the Logmonitor log level string.
  ///
  /// - [Level.SEVERE] → `'error'`
  /// - [Level.WARNING] → `'warn'`
  /// - [Level.INFO] → `'info'`
  /// - All others → `'log'`
  String _mapLogLevel(Level level) {
    if (level == Level.SEVERE) return 'error';
    if (level == Level.SHOUT) return 'error';
    if (level == Level.WARNING) return 'warn';
    if (level == Level.INFO) return 'info';
    return 'log';
  }

  /// Starts the periodic timer that flushes the log buffer every
  /// [_batchPeriod].
  void _startBatchTimer() {
    _batchTimer = Timer.periodic(_batchPeriod, (timer) {
      if (_logBuffer.isNotEmpty) {
        _sendLogs();
      }
    });
  }

  /// Sends all buffered logs to the Logmonitor backend.
  ///
  /// On failure (non-202 status or network error), the logs are re-inserted
  /// at the front of the buffer so they can be retried on the next cycle.
  Future<void> _sendLogs() async {
    if (_apiKey == null || _logBuffer.isEmpty) return;
    final List<Map<String, dynamic>> batchToSend = List.from(_logBuffer);
    _logBuffer.clear();
    final headers = {
      'Content-Type': 'application/json',
      'X-Logmonitor-Api-Key': _apiKey!,
      'X-Logmonitor-Bundle-Id': ?_bundleId,
    };
    try {
      final response = await http.post(
        Uri.parse(_endpoint),
        headers: headers,
        body: json.encode(batchToSend),
      );
      if (response.statusCode != 202) {
        _internalDebugPrint(
          "Logmonitor: Failed to send logs (Status ${response.statusCode}). Retrying next cycle.",
        );
        _logBuffer.insertAll(0, batchToSend);
      }
    } catch (e) {
      _internalDebugPrint("Logmonitor: Error sending logs: $e. Retrying next cycle.");
      _logBuffer.insertAll(0, batchToSend);
    }
  }
}
