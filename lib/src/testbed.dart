// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file/memory.dart';
import 'package:reporting/reporting.dart';
import 'package:tool_base/src/base/context.dart';
import 'package:tool_base/src/base/file_system.dart';
import 'package:tool_base/src/base/io.dart';
import 'package:tool_base/src/base/logger.dart';
import 'package:tool_base/src/base/os.dart';
import 'package:tool_base/src/base/platform.dart';
import 'package:tool_base/src/base/terminal.dart';
import 'package:tool_base/src/cache.dart';
import 'package:mockito/mockito.dart';
//import 'package:tool_base/src/context_runner.dart';
//import 'package:tool_base/src/features.dart';
//import 'package:tool_base/src/reporting/reporting.dart';
//import 'package:tool_base/src/version.dart';

import 'context.dart';
import 'context_runner.dart';

export 'package:tool_base/src/base/context.dart' show Generator;

// A default value should be provided if the vast majority of tests should use
// this provider. For example, [BufferLogger], [MemoryFileSystem].
final Map<Type, Generator> _testbedDefaults = <Type, Generator>{
  // Keeps tests fast by avoiding the actual file system.
  FileSystem: () => MemoryFileSystem(
      style:
          platform.isWindows ? FileSystemStyle.windows : FileSystemStyle.posix),
  Logger: () => BufferLogger(), // Allows reading logs and prevents stdout.
  OperatingSystemUtils: () => FakeOperatingSystemUtils(),
  OutputPreferences: () => OutputPreferences(
      showColor: false), // configures BufferLogger to avoid color codes.
//  Usage: () => NoOpUsage(), // prevent addition of analytics from burdening test mocks
//  FlutterVersion: () => FakeFlutterVersion() // prevent requirement to mock git for test runner.
};

/// Manages interaction with the tool injection and runner system.
///
/// The Testbed automatically injects reasonable defaults through the context
/// DI system such as a [BufferLogger] and a [MemoryFileSytem].
///
/// Example:
///
/// Testing that a filesystem operation works as expected
///
///     void main() {
///       group('Example', () {
///         Testbed testbed;
///
///         setUp(() {
///           testbed = Testbed(setUp: () {
///             fs.file('foo').createSync()
///           });
///         })
///
///         test('Can delete a file', () => testBed.run(() {
///           expect(fs.file('foo').existsSync(), true);
///           fs.file('foo').deleteSync();
///           expect(fs.file('foo').existsSync(), false);
///         }));
///       });
///     }
///
/// For a more detailed example, see the code in test_compiler_test.dart.
class Testbed {
  /// Creates a new [TestBed]
  ///
  /// `overrides` provides more overrides in addition to the test defaults.
  /// `setup` may be provided to apply mocks within the tool managed zone,
  /// including any specified overrides.
  Testbed({FutureOr<void> Function()? setup, Map<Type, Generator>? overrides})
      : _setup = setup,
        _overrides = overrides;

  final FutureOr<void> Function()? _setup;
  final Map<Type, Generator>? _overrides;

  /// Runs `test` within a tool zone.
  ///
  /// `overrides` may be used to provide new context values for the single test
  /// case or override any context values from the setup.
  FutureOr<T> run<T>(FutureOr<T> Function() test,
      {Map<Type, Generator>? overrides}) {
    final Map<Type, Generator> testOverrides = <Type, Generator>{
      ..._testbedDefaults,
      // Add the initial setUp overrides
      ...?_overrides,
      // Add the test-specific overrides
      ...?overrides,
    };
    // Cache the original flutter root to restore after the test case.
    final String originalFlutterRoot = Cache.flutterRoot;
    // Track pending timers to verify that they were correctly cleaned up.
    final Map<Timer, StackTrace> timers = <Timer, StackTrace>{};

    return HttpOverrides.runZoned(() {
      return runInContext<T>(() {
        return context.run<T>(
            name: 'testbed',
            overrides: testOverrides,
            zoneSpecification: ZoneSpecification(createTimer: (Zone self,
                ZoneDelegate parent,
                Zone zone,
                Duration duration,
                void Function() timer) {
              final Timer result = parent.createTimer(zone, duration, timer);
              timers[result] = StackTrace.current;
              return result;
            }, createPeriodicTimer: (Zone self, ZoneDelegate parent, Zone zone,
                Duration period, void Function(Timer) timer) {
              final Timer result =
                  parent.createPeriodicTimer(zone, period, timer);
              timers[result] = StackTrace.current;
              return result;
            }),
            body: () async {
              Cache.flutterRoot = '';
              if (_setup != null) {
                await _setup!();
              }
              var result = await test();
              Cache.flutterRoot = originalFlutterRoot;
              for (MapEntry<Timer, StackTrace> entry in timers.entries) {
                if (entry.key.isActive) {
                  throw StateError(
                      'A Timer was active at the end of a test: ${entry.value}');
                }
              }
              return result;
            });
      });
    }, createHttpClient: (SecurityContext? c) => FakeHttpClient());
  }
}

/// A no-op implementation of [Usage] for testing.
class NoOpUsage implements Usage {
  @override
  bool enabled = false;

  @override
  bool suppressAnalytics = true;

  @override
  String get clientId => 'test';

  @override
  Future<void> ensureAnalyticsSent() async {
    return;
  }

  @override
  bool get isFirstRun => false;

  @override
  Stream<Map<String, Object>> get onSend =>
      const Stream<Map<String, Object>>.empty();

  @override
  void printWelcome() {}

  @override
  void sendCommand(String command, {Map<String, String>? parameters}) {}

  @override
  void sendEvent(String category, String parameter,
      {Map<String, String>? parameters}) {}

  @override
  void sendException(dynamic exception) {}

  @override
  void sendTiming(String category, String variableName, Duration duration,
      {String? label}) {}
}

class FakeHttpClient implements HttpClient {
  @override
  void addCredentials(
      Uri url, String realm, HttpClientCredentials credentials) {}

  @override
  void addProxyCredentials(
      String host, int port, String realm, HttpClientCredentials credentials) {}

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> head(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> headUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> patchUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> post(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> put(String host, int port, String path) async {
    return FakeHttpClientRequest();
  }

  @override
  Future<HttpClientRequest> putUrl(Uri url) async {
    return FakeHttpClientRequest();
  }

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  int? maxConnectionsPerHost;

  @override
  String? userAgent;

  @override
  set authenticate(
      Future<bool> Function(Uri url, String scheme, String? realm)? f) {}

  @override
  set authenticateProxy(
      Future<bool> Function(
              String host, int port, String scheme, String? realm)?
          f) {}

  @override
  set badCertificateCallback(
      bool Function(X509Certificate cert, String host, int port)? callback) {}

  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(
              Uri url, String? proxyHost, int? proxyPort)?
          f) {}

  @override
  set findProxy(String Function(Uri url)? f) {}

  @override
  set keyLog(Function(String line)? callback) {}
}

class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest();

  @override
  bool bufferOutput = true;

  @override
  int contentLength = -1;

  @override
  Encoding encoding = utf8;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  void add(List<int> data) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<HttpClientResponse> close() async {
    return FakeHttpClientResponse();
  }

  @override
  List<Cookie> get cookies => <Cookie>[];

  @override
  Future<void> flush() {
    return Future<void>.value();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  Future<HttpClientResponse> get done =>
      Future.value(EmptyHttpClientResponse());

  @override
  HttpHeaders get headers => FakeHttpHeaders();

  @override
  String get method => "none";

  @override
  Uri get uri => Uri.base;

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable objects, [String separator = ""]) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = ""]) {}
}

class EmptyHttpClientResponse extends Mock implements HttpClientResponse {
  EmptyHttpClientResponse();
  final Map<Uri, List<int>> data = {};
  Uri? requestedUrl;

  // It is not necessary to override this method to pass the test.
  @override
  Future<S> fold<S>(
    S initialValue,
    S Function(S previous, List<int> element) combine,
  ) {
    return Stream.fromIterable([data[requestedUrl]])
        .fold(initialValue, combine as S Function(S, List<int>?));
  }
}

class FakeHttpClientResponse implements HttpClientResponse {
  final Stream<List<int>> _delegate =
      Stream<List<int>>.fromIterable(const Iterable<List<int>>.empty());

  @override
  final HttpHeaders headers = FakeHttpHeaders();

  @override
  int get contentLength => 0;

  @override
  HttpClientResponseCompressionState get compressionState {
    return HttpClientResponseCompressionState.decompressed;
  }

  @override
  Future<Socket> detachSocket() {
    return Future<Socket>.error(UnsupportedError('Mocked response'));
  }

  @override
  bool get isRedirect => false;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => "mock reason";

  // @override
  // Future<HttpClientResponse> redirect(
  //     [String method, Uri url, bool followLoops]) {
  //   return Future<HttpClientResponse>.error(
  //       UnsupportedError('Mocked response'));
  // }

  @override
  List<RedirectInfo> get redirects => <RedirectInfo>[];

  @override
  int get statusCode => 400;

  @override
  Future<bool> any(bool Function(List<int> element) test) {
    return _delegate.any(test);
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(List<int> event) convert) {
    return _delegate.asyncMap<E>(convert);
  }

  @override
  Stream<R> cast<R>() {
    return _delegate.cast<R>();
  }

  @override
  Future<List<int>> elementAt(int index) {
    return _delegate.elementAt(index);
  }

  @override
  Future<bool> every(bool Function(List<int> element) test) {
    return _delegate.every(test);
  }

  @override
  Stream<S> expand<S>(Iterable<S> Function(List<int> element) convert) {
    return _delegate.expand(convert);
  }

  @override
  Future<List<int>> get first => _delegate.first;

  @override
  Future<S> fold<S>(
      S initialValue, S Function(S previous, List<int> element) combine) {
    return _delegate.fold<S>(initialValue, combine);
  }

  @override
  Future<dynamic> forEach(void Function(List<int> element) action) {
    return _delegate.forEach(action);
  }

  @override
  bool get isBroadcast => _delegate.isBroadcast;

  @override
  Future<bool> get isEmpty => _delegate.isEmpty;

  @override
  Future<String> join([String separator = '']) {
    return _delegate.join(separator);
  }

  @override
  Future<List<int>> get last => _delegate.last;

  @override
  Future<int> get length => _delegate.length;

  @override
  Stream<S> map<S>(S Function(List<int> event) convert) {
    return _delegate.map<S>(convert);
  }

  @override
  Future<List<int>> get single => _delegate.single;

  @override
  Stream<List<int>> skip(int count) {
    return _delegate.skip(count);
  }

  @override
  Stream<List<int>> skipWhile(bool Function(List<int> element) test) {
    return _delegate.skipWhile(test);
  }

  @override
  Stream<List<int>> take(int count) {
    return _delegate.take(count);
  }

  @override
  Stream<List<int>> takeWhile(bool Function(List<int> element) test) {
    return _delegate.takeWhile(test);
  }

  @override
  Stream<List<int>> timeout(
    Duration timeLimit, {
    void Function(EventSink<List<int>> sink)? onTimeout,
  }) {
    return _delegate.timeout(timeLimit, onTimeout: onTimeout);
  }

  @override
  Future<List<List<int>>> toList() {
    return _delegate.toList();
  }

  @override
  Future<Set<List<int>>> toSet() {
    return _delegate.toSet();
  }

  @override
  Stream<List<int>> where(bool Function(List<int> event) test) {
    return _delegate.where(test);
  }

  @override
  Stream<List<int>> asBroadcastStream(
      {void Function(StreamSubscription<List<int>> subscription)? onListen,
      void Function(StreamSubscription<List<int>> subscription)? onCancel}) {
    return _delegate.asBroadcastStream(onListen: onListen, onCancel: onCancel);
  }

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(List<int> event) convert) {
    return _delegate.asyncExpand(convert);
  }

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  Future<bool> contains(Object? needle) {
    return _delegate.contains(needle);
  }

  @override
  List<Cookie> get cookies => [];

  @override
  Stream<List<int>> distinct(
      [bool Function(List<int> previous, List<int> next)? equals]) {
    return _delegate.distinct(equals);
  }

  @override
  Future<E> drain<E>([E? futureValue]) {
    return _delegate.drain<E>(futureValue);
  }

  @override
  Future<List<int>> firstWhere(bool Function(List<int> element) test,
      {List<int> Function()? orElse}) {
    return _delegate.firstWhere(test, orElse: orElse);
  }

  @override
  Stream<List<int>> handleError(Function onError,
      {bool Function(dynamic error)? test}) {
    return _delegate.handleError(onError, test: test);
  }

  @override
  Future<List<int>> lastWhere(bool Function(List<int> element) test,
      {List<int> Function()? orElse}) {
    return _delegate.lastWhere(test, orElse: orElse);
  }

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _delegate.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future pipe(StreamConsumer<List<int>> streamConsumer) {
    return _delegate.pipe(streamConsumer);
  }

  @override
  Future<HttpClientResponse> redirect(
      [String? method, Uri? url, bool? followLoops]) {
    return Future<HttpClientResponse>.error(
        UnsupportedError('Mocked response'));
  }

  @override
  Future<List<int>> reduce(
      List<int> Function(List<int> previous, List<int> element) combine) {
    return _delegate.reduce(combine);
  }

  @override
  Future<List<int>> singleWhere(bool Function(List<int> element) test,
      {List<int> Function()? orElse}) {
    return _delegate.singleWhere(test, orElse: orElse);
  }

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> streamTransformer) {
    return _delegate.transform(streamTransformer);
  }
}

/// A fake [HttpHeaders] that ignores all writes.
class FakeHttpHeaders extends HttpHeaders {
  @override
  List<String> operator [](String name) => <String>[];

  @override
  void clear() {}

  @override
  void forEach(void Function(String name, List<String> values) f) {}

  @override
  void noFolding(String name) {}

  @override
  void remove(String name, Object value) {}

  @override
  void removeAll(String name) {}

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;
}

//class FakeFlutterVersion implements FlutterVersion {
//  @override
//  String get channel => 'master';
//
//  @override
//  Future<void> checkFlutterVersionFreshness() async { }
//
//  @override
//  bool checkRevisionAncestry({String tentativeDescendantRevision, String tentativeAncestorRevision}) {
//    throw UnimplementedError();
//  }
//
//  @override
//  String get dartSdkVersion => '12';
//
//  @override
//  String get engineRevision => '42.2';
//
//  @override
//  String get engineRevisionShort => '42';
//
//  @override
//  Future<void> ensureVersionFile() async { }
//
//  @override
//  String get frameworkAge => null;
//
//  @override
//  String get frameworkCommitDate => null;
//
//  @override
//  String get frameworkDate => null;
//
//  @override
//  String get frameworkRevision => null;
//
//  @override
//  String get frameworkRevisionShort => null;
//
//  @override
//  String get frameworkVersion => null;
//
//  @override
//  String getBranchName({bool redactUnknownBranches = false}) {
//    return 'master';
//  }
//
//  @override
//  String getVersionString({bool redactUnknownBranches = false}) {
//    return 'v0.0.0';
//  }
//
//  @override
//  bool get isMaster => true;
//
//  @override
//  String get repositoryUrl => null;
//
//  @override
//  Map<String, Object> toJson() {
//    return null;
//  }
//}
//
//// A test implementation of [FeatureFlags] that allows enabling without reading
//// config. If not otherwise specified, all values default to false.
//class TestFeatureFlags implements FeatureFlags {
//  TestFeatureFlags({
//    this.isLinuxEnabled = false,
//    this.isMacOSEnabled = false,
//    this.isWebEnabled = false,
//    this.isWindowsEnabled = false,
//    this.isPluginAsAarEnabled = false,
//  });
//
//  @override
//  final bool isLinuxEnabled;
//
//  @override
//  final bool isMacOSEnabled;
//
//  @override
//  final bool isWebEnabled;
//
//  @override
//  final bool isWindowsEnabled;
//
//  @override
//  final bool isPluginAsAarEnabled;
//}
