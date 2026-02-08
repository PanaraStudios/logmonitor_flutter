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
///   await Logmonitor.init(apiKey: 'YOUR_API_KEY');
///
///   final log = Logger('MyApp');
///   log.info('Application started');
///
///   runApp(const MyApp());
/// }
/// ```
///
/// ## How It Works
///
/// The SDK integrates with Dart's built-in [Logger] from `package:logging`.
/// Once initialized, it automatically captures all log records and batches
/// them for efficient delivery to the Logmonitor backend.
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
///    `WidgetsFlutterBinding.ensureInitialized()`).
/// 2. Optionally call [setUser] / [clearUser] to tag logs with a user ID.
/// 3. Call [dispose] when the app is closing to flush remaining logs.
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
      "https://aromatic-duck-387.convex.site/api/v1/logs";
  String? _apiKey;
  String? _bundleId;
  String? _logUserId;

  final List<Map<String, dynamic>> _logBuffer = [];
  Timer? _batchTimer;
  StreamSubscription<LogRecord>? _logSubscription;

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
  /// In **debug mode**, logs are only printed to the console and are not
  /// sent to the server. In **release mode**, logs are batched and sent
  /// automatically.
  ///
  /// Calling this method more than once has no effect.
  ///
  /// ```dart
  /// await Logmonitor.init(apiKey: 'YOUR_API_KEY');
  /// ```
  static Future<void> init({required String apiKey}) async {
    if (_instance._apiKey != null) {
      debugPrint("Logmonitor is already initialized.");
      return;
    }
    _instance._apiKey = apiKey;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _instance._bundleId = packageInfo.packageName;
    } catch (e) {
      debugPrint("Logmonitor: Could not get package info. $e");
    }

    Logger.root.level = Level.ALL;

    _instance._logSubscription = Logger.root.onRecord.listen((
      LogRecord record,
    ) {
      if (kDebugMode) {
        debugPrint(
          '[${record.level.name}] ${record.time}: ${record.loggerName}: ${record.message}',
        );
      } else {
        _instance._addLog(record);
      }
    });

    if (!kDebugMode) {
      _instance._startBatchTimer();
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

    debugPrint("Disposing Logmonitor...");

    await _instance._logSubscription?.cancel();
    _instance._logSubscription = null;

    _instance._batchTimer?.cancel();
    _instance._batchTimer = null;

    await _instance._sendLogs();

    _instance._apiKey = null;
    _instance._logUserId = null;
    _instance._logBuffer.clear();

    debugPrint("Logmonitor disposed and shut down.");
  }

  // --- Private Helper Methods ---

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
      if (record.stackTrace != null)
        'stackTrace': record.stackTrace.toString(),
    };
    final logData = {
      'level': _mapLogLevel(record.level),
      'message': record.message,
      'clientTimestamp': record.time.millisecondsSinceEpoch,
      'logUserId': _logUserId ?? '',
      'payload': payload.isNotEmpty ? payload : null,
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
        debugPrint(
          "Logmonitor: Failed to send logs (Status ${response.statusCode}). Retrying next cycle.",
        );
        _logBuffer.insertAll(0, batchToSend);
      }
    } catch (e) {
      debugPrint("Logmonitor: Error sending logs: $e. Retrying next cycle.");
      _logBuffer.insertAll(0, batchToSend);
    }
  }
}
