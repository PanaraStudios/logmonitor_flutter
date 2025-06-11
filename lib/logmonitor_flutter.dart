import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:logging/logging.dart';

class Logmonitor {
  // --- Singleton Setup ---
  static final Logmonitor _instance = Logmonitor._internal();
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
  StreamSubscription<LogRecord>? _logSubscription; // To hold the listener

  static const int _maxBatchSize = 20;
  static const Duration _batchPeriod = Duration(seconds: 15);

  /// Initializes Logmonitor to listen for logs.
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

    // Store the subscription so we can cancel it later
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

  /// Associates subsequent logs with a specific user ID.
  static void setUser({required String userId}) {
    _instance._logUserId = userId;
  }

  /// Clears the user association.
  static void clearUser() {
    _instance._logUserId = null;
  }

  /// Disposes of the Logmonitor instance, sends any remaining logs,
  /// and cleans up resources. Should be called when the app is closing.
  static Future<void> dispose() async {
    if (_instance._apiKey == null) return; // Not initialized

    debugPrint("Disposing Logmonitor...");

    // Stop listening to new logs
    await _instance._logSubscription?.cancel();
    _instance._logSubscription = null;

    // Stop the periodic timer
    _instance._batchTimer?.cancel();
    _instance._batchTimer = null;

    // Send any remaining logs in the buffer
    await _instance._sendLogs();

    // Clear state
    _instance._apiKey = null;
    _instance._logUserId = null;
    _instance._logBuffer.clear();

    debugPrint("Logmonitor disposed and shut down.");
  }

  // --- Private Helper Methods ---
  // _addLog, _mapLogLevel, _startBatchTimer, and _sendLogs methods remain the same...

  void _addLog(LogRecord record) {
    final logData = {
      'level': _mapLogLevel(record.level),
      'message': record.message,
      'clientTimestamp': record.time.millisecondsSinceEpoch,
      'logUserId': _logUserId,
      'payload': record.object,
    };
    _logBuffer.add(logData);
    if (_logBuffer.length >= _maxBatchSize) {
      _sendLogs();
    }
  }

  String _mapLogLevel(Level level) {
    if (level == Level.SEVERE) return 'error';
    if (level == Level.WARNING) return 'warn';
    if (level == Level.INFO) return 'info';
    return 'log';
  }

  void _startBatchTimer() {
    _batchTimer = Timer.periodic(_batchPeriod, (timer) {
      if (_logBuffer.isNotEmpty) {
        _sendLogs();
      }
    });
  }

  Future<void> _sendLogs() async {
    if (_apiKey == null || _logBuffer.isEmpty) return;
    final List<Map<String, dynamic>> batchToSend = List.from(_logBuffer);
    _logBuffer.clear();
    final headers = {
      'Content-Type': 'application/json',
      'X-Logmonitor-Api-Key': _apiKey!,
      if (_bundleId != null) 'X-Logmonitor-Bundle-Id': _bundleId!,
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
