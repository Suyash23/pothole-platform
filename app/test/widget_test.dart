// Smoke test for the Road Quality Mapper home screen.
//
// The app is pumped with an injected fake recorder so the test never touches
// Firebase, sqflite, or path_provider (the real recorder's initState work —
// loadLatestTrip / upload retries — would throw MissingPluginException in the
// test binding). HttpOverrides serves an in-memory transparent PNG for the
// OSM tile requests, which the default test binding would otherwise fail
// with HTTP 400.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pothole_finder/main.dart';
import 'package:pothole_finder/recorder.dart';
import 'package:pothole_finder/road_db.dart';

void main() {
  setUpAll(() {
    HttpOverrides.global = _FakeTileHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = null;
  });

  testWidgets('Road Quality Mapper UI smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(RoadQualityApp(recorder: _FakeRecorder()));
    await tester.pump();

    // Title in the AppBar.
    expect(find.text('Road Quality Mapper'), findsOneWidget);

    // Not recording: status bar shows 'Idle' and the Start button is offered.
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);

    // Stop only exists while a recording is in progress.
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets(
      'side correction panel: fixed order, titleMedium text, tap-to-correct '
      'and tap-own-type-to-confirm', (WidgetTester tester) async {
    final recorder = _AlertFakeRecorder();
    await tester.pumpWidget(RoadQualityApp(recorder: recorder));
    await tester.pump();

    // Idle, no alert → no panel.
    expect(find.widgetWithText(InkWell, 'Joint'), findsNothing);

    recorder.beginFakeRecording();
    await tester.pump();

    // A pothole alert fires.
    recorder.emit(AnomalyEvent(
        ts: DateTime.now().millisecondsSinceEpoch,
        type: 'pothole',
        zScore: 3.2,
        peakG: 0.5));
    await tester.pump();
    await tester.pump();

    // All four options present, ALWAYS in the same top-to-bottom order.
    const labels = ['Pothole', 'Bump', 'Joint', 'Rough Road'];
    final ys = <double>[];
    for (final l in labels) {
      final f = find.widgetWithText(InkWell, l);
      expect(f, findsOneWidget, reason: '"$l" option missing from panel');
      ys.add(tester.getTopLeft(f).dy);
    }
    for (int i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]),
          reason: 'panel options out of fixed order');
    }

    // Text size matches the status bar's Idle / Recording… (titleMedium).
    final BuildContext ctx = tester.element(find.widgetWithText(InkWell, 'Joint'));
    final Text jointText = tester.widget<Text>(find.descendant(
        of: find.widgetWithText(InkWell, 'Joint'),
        matching: find.text('Joint')));
    expect(jointText.style?.fontSize,
        Theme.of(ctx).textTheme.titleMedium?.fontSize);

    // Tapping a DIFFERENT type records a pothole → joint reclassification and
    // resolves the alert (panel hides).
    await tester.tap(find.widgetWithText(InkWell, 'Joint'));
    await tester.pump();
    expect(recorder.gtCalls, contains('reclassify:pothole->concrete_joint'));
    expect(find.widgetWithText(InkWell, 'Rough Road'), findsNothing);
    await tester.pump(const Duration(seconds: 3)); // dismiss timer

    // Next alert: tapping the alert's OWN (highlighted) type is a confirm.
    recorder.emit(AnomalyEvent(
        ts: DateTime.now().millisecondsSinceEpoch,
        type: 'pothole',
        zScore: 2.8,
        peakG: 0.4));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.widgetWithText(InkWell, 'Pothole'));
    await tester.pump();
    expect(recorder.gtCalls, contains('confirm:pothole'));
    await tester.pump(const Duration(seconds: 3)); // dismiss timer

    // Unmount so the alert controller's timers are cancelled before the
    // pending-timer check.
    await tester.pumpWidget(const SizedBox());
  });
}

/// [_FakeRecorder] plus a controllable alert stream and recording flag, and
/// ground-truth writers that record their calls instead of touching sqlite.
class _AlertFakeRecorder extends _FakeRecorder {
  final StreamController<AnomalyEvent> _alerts =
      StreamController<AnomalyEvent>.broadcast();
  bool _fakeRecording = false;
  final List<String> gtCalls = [];

  @override
  bool get isRecording => _fakeRecording;

  @override
  Stream<AnomalyEvent> get anomalyStream => _alerts.stream;

  void beginFakeRecording() {
    _fakeRecording = true;
    notifyListeners();
  }

  void emit(AnomalyEvent e) => _alerts.add(e);

  @override
  Future<void> confirmDetectorEvent(int ts, String type,
      {double zScore = 0.0}) async {
    gtCalls.add('confirm:$type');
  }

  @override
  Future<void> rejectDetectorEvent(int ts, String type,
      {double zScore = 0.0}) async {
    gtCalls.add('reject:$type');
  }

  @override
  Future<void> reclassifyDetectorEvent(
      int ts, String detectedType, String correctedType,
      {double zScore = 0.0}) async {
    gtCalls.add('reclassify:$detectedType->$correctedType');
  }
}

/// Recorder whose startup side effects (sqlite reads, Firestore upload
/// retries) are no-ops. Everything else — getters, notifier plumbing,
/// stop()-when-idle — is the real implementation.
class _FakeRecorder extends RoadRecorder {
  _FakeRecorder() : super(RoadDb.instance);

  @override
  Future<void> loadLatestTrip() async {}

  @override
  Future<void> refreshPendingUploadCount() async {}

  @override
  Future<bool> retryUnuploadedTrips() async => true;
}

// ─── HTTP mocking ────────────────────────────────────────────────────────────
// flutter_map's NetworkTileProvider goes through dart:io HttpClient, so a
// HttpOverrides that answers every request with a 200 + 1×1 transparent PNG
// keeps the tile layer happy without any network access.

/// 1×1 transparent PNG (the classic `kTransparentImage` bytes).
const List<int> _transparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

class _FakeTileHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  Duration? connectionTimeout;

  @override
  int? maxConnectionsPerHost;

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest(url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpClientRequest(url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.uri);

  @override
  final Uri uri;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  String get method => 'GET';

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> flush() async {}

  @override
  Future<HttpClientResponse> close() async => _FakeHttpClientResponse();

  @override
  Future<HttpClientResponse> get done async => _FakeHttpClientResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  String get reasonPhrase => 'OK';

  @override
  int get contentLength => _transparentPng.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(_transparentPng).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  @override
  ContentType? contentType = ContentType('image', 'png');

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  List<String>? operator [](String name) =>
      name.toLowerCase() == HttpHeaders.contentTypeHeader
          ? const ['image/png']
          : null;

  @override
  String? value(String name) => this[name]?.first;

  @override
  void forEach(void Function(String name, List<String> values) action) {
    action(HttpHeaders.contentTypeHeader, const ['image/png']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
