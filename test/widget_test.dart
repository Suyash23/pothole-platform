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
