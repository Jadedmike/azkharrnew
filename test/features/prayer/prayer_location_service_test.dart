import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_service.dart';

/// Configurable fake [GeolocatorClient] + [LastKnownPositionProvider] for
/// deterministic unit testing without touching device GPS or platform channels.
class _FakeGeolocatorClient
    implements GeolocatorClient, LastKnownPositionProvider {
  bool serviceEnabled;
  LocationPermission initialPermission;
  LocationPermission requestedPermission;
  Position? positionToReturn;
  Object? errorToThrowOnGetPosition;

  /// Optional per-call handlers for multi-attempt sequences and hangs.
  Future<bool> Function()? serviceEnabledHandler;
  Future<LocationPermission> Function()? checkPermissionHandler;
  Future<Position> Function(LocationSettings settings, int callIndex)?
      getPositionHandler;
  Future<Position?> Function(bool forceAndroidLocationManager)?
      getLastKnownHandler;

  int isServiceEnabledCalls = 0;
  int checkPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int getCurrentPositionCalls = 0;
  int getLastKnownCalls = 0;
  final List<LocationSettings> recordedLocationSettings = <LocationSettings>[];
  final List<bool> recordedLastKnownForceFlags = <bool>[];
  LocationSettings? lastLocationSettings;

  _FakeGeolocatorClient({
    this.serviceEnabled = true,
    this.initialPermission = LocationPermission.whileInUse,
    this.requestedPermission = LocationPermission.whileInUse,
    Position? positionToReturn,
    this.errorToThrowOnGetPosition,
    this.serviceEnabledHandler,
    this.checkPermissionHandler,
    this.getPositionHandler,
    this.getLastKnownHandler,
  }) : positionToReturn = positionToReturn ??
            Position(
              latitude: 21.4225,
              longitude: 39.8262,
              timestamp: DateTime.utc(2026, 3, 20, 12, 0),
              accuracy: 12.5,
              altitude: 0.0,
              altitudeAccuracy: 0.0,
              heading: 0.0,
              headingAccuracy: 0.0,
              speed: 0.0,
              speedAccuracy: 0.0,
              hasAccuracy: true,
            );

  @override
  Future<bool> isLocationServiceEnabled() async {
    isServiceEnabledCalls++;
    if (serviceEnabledHandler != null) {
      return serviceEnabledHandler!();
    }
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    checkPermissionCalls++;
    if (checkPermissionHandler != null) {
      return checkPermissionHandler!();
    }
    return initialPermission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    return requestedPermission;
  }

  @override
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  }) async {
    getCurrentPositionCalls++;
    lastLocationSettings = locationSettings;
    recordedLocationSettings.add(locationSettings);
    if (getPositionHandler != null) {
      return getPositionHandler!(locationSettings, getCurrentPositionCalls);
    }
    if (errorToThrowOnGetPosition != null) {
      throw errorToThrowOnGetPosition!;
    }
    return positionToReturn!;
  }

  @override
  Future<Position?> getLastKnownPosition({
    bool forceAndroidLocationManager = false,
  }) async {
    getLastKnownCalls++;
    recordedLastKnownForceFlags.add(forceAndroidLocationManager);
    if (getLastKnownHandler != null) {
      return getLastKnownHandler!(forceAndroidLocationManager);
    }
    return null;
  }
}

Position _buildPos(
  double lat,
  double lng, {
  required DateTime timestamp,
  double accuracy = 15.0,
}) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: timestamp,
    accuracy: accuracy,
    altitude: 0.0,
    altitudeAccuracy: 0.0,
    heading: 0.0,
    headingAccuracy: 0.0,
    speed: 0.0,
    speedAccuracy: 0.0,
    hasAccuracy: true,
  );
}

void main() {
  group('PrayerLocationService Unit Tests', () {
    test('no location or permission request occurs during service initialization', () {
      final fakeClient = _FakeGeolocatorClient();
      final service = PrayerLocationService(client: fakeClient);

      expect(service.timeout, equals(PrayerLocationService.defaultTimeout));
      expect(fakeClient.isServiceEnabledCalls, equals(0));
      expect(fakeClient.checkPermissionCalls, equals(0));
      expect(fakeClient.requestPermissionCalls, equals(0));
      expect(fakeClient.getCurrentPositionCalls, equals(0));
    });

    test('successful location retrieval when foreground permission is already granted', () async {
      final fakeClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.whileInUse,
      );
      final service = PrayerLocationService(client: fakeClient);

      final result = await service.getCurrentLocation();

      expect(result.isSuccess, isTrue);
      expect(result.isFailure, isFalse);
      expect(result.failureReason, isNull);
      expect(result.coordinates, isNotNull);
      expect(result.coordinates!.latitude, equals(21.4225));
      expect(result.coordinates!.longitude, equals(39.8262));
      expect(result.coordinates!.accuracy, equals(12.5));

      expect(fakeClient.isServiceEnabledCalls, equals(1));
      expect(fakeClient.checkPermissionCalls, equals(1));
      expect(fakeClient.requestPermissionCalls, equals(0));
      expect(fakeClient.getCurrentPositionCalls, equals(1));
    });

    test('requests foreground permission when initially denied and succeeds if granted', () async {
      final fakeClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.denied,
        requestedPermission: LocationPermission.whileInUse,
      );
      final service = PrayerLocationService(client: fakeClient);

      final result = await service.getCurrentLocation();

      expect(result.isSuccess, isTrue);
      expect(result.coordinates!.latitude, equals(21.4225));
      expect(fakeClient.checkPermissionCalls, equals(1));
      expect(fakeClient.requestPermissionCalls, equals(1));
      expect(fakeClient.getCurrentPositionCalls, equals(1));
    });

    test('handles permission denied when user declines permission prompt', () async {
      final fakeClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.denied,
        requestedPermission: LocationPermission.denied,
      );
      final service = PrayerLocationService(client: fakeClient);

      final result = await service.getCurrentLocation();

      expect(result.isFailure, isTrue);
      expect(result.coordinates, isNull);
      expect(
        result.failureReason,
        equals(PrayerLocationFailureReason.permissionDenied),
      );
      expect(fakeClient.requestPermissionCalls, equals(1));
      expect(fakeClient.getCurrentPositionCalls, equals(0));
    });

    test('handles permission denied forever without prompting or fetching position', () async {
      final fakeClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.deniedForever,
      );
      final service = PrayerLocationService(client: fakeClient);

      final result = await service.getCurrentLocation();

      expect(result.isFailure, isTrue);
      expect(result.coordinates, isNull);
      expect(
        result.failureReason,
        equals(PrayerLocationFailureReason.permissionDeniedForever),
      );
      // Must not call requestPermission when already deniedForever
      expect(fakeClient.requestPermissionCalls, equals(0));
      expect(fakeClient.getCurrentPositionCalls, equals(0));

      // Also handles transition from denied -> deniedForever after prompt
      final transitionClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.denied,
        requestedPermission: LocationPermission.deniedForever,
      );
      final transitionService = PrayerLocationService(client: transitionClient);
      final transitionResult = await transitionService.getCurrentLocation();
      expect(
        transitionResult.failureReason,
        equals(PrayerLocationFailureReason.permissionDeniedForever),
      );
      expect(transitionClient.requestPermissionCalls, equals(1));
      expect(transitionClient.getCurrentPositionCalls, equals(0));
    });

    test('handles location services disabled before and during position request', () async {
      final disabledClient = _FakeGeolocatorClient(serviceEnabled: false);
      final service = PrayerLocationService(client: disabledClient);

      final result = await service.getCurrentLocation();

      expect(result.isFailure, isTrue);
      expect(result.coordinates, isNull);
      expect(
        result.failureReason,
        equals(PrayerLocationFailureReason.serviceDisabled),
      );
      expect(disabledClient.checkPermissionCalls, equals(0));
      expect(disabledClient.requestPermissionCalls, equals(0));
      expect(disabledClient.getCurrentPositionCalls, equals(0));

      // Exception thrown during getCurrentPosition
      final midRequestDisabledClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        errorToThrowOnGetPosition: const LocationServiceDisabledException(),
      );
      final midService = PrayerLocationService(client: midRequestDisabledClient);
      final midResult = await midService.getCurrentLocation();
      expect(
        midResult.failureReason,
        equals(PrayerLocationFailureReason.serviceDisabled),
      );
    });

    test('handles location timeout cleanly', () async {
      final timeoutClient = _FakeGeolocatorClient(
        serviceEnabled: true,
        initialPermission: LocationPermission.whileInUse,
        errorToThrowOnGetPosition: TimeoutException('GPS fix timed out'),
      );
      final service = PrayerLocationService(client: timeoutClient);

      final result = await service.getCurrentLocation();

      expect(result.isFailure, isTrue);
      expect(result.coordinates, isNull);
      expect(
        result.failureReason,
        equals(PrayerLocationFailureReason.timeout),
      );
      expect(result.cause, isA<TimeoutException>());
    });

    test('handles position unavailable and platform exceptions cleanly', () async {
      // PositionUpdateException -> positionUnavailable
      final unavailableClient = _FakeGeolocatorClient(
        errorToThrowOnGetPosition:
            const PositionUpdateException('No satellite fix'),
      );
      final unavailableService = PrayerLocationService(
        client: unavailableClient,
      );
      final unavailableResult = await unavailableService.getCurrentLocation();
      expect(
        unavailableResult.failureReason,
        equals(PrayerLocationFailureReason.positionUnavailable),
      );

      // PlatformException -> platformFailure
      final platformErrorClient = _FakeGeolocatorClient(
        errorToThrowOnGetPosition: PlatformException(
          code: 'LOCATION_ERROR',
          message: 'Native location provider error',
        ),
      );
      final platformErrorService = PrayerLocationService(
        client: platformErrorClient,
      );
      final platformResult = await platformErrorService.getCurrentLocation();
      expect(
        platformResult.failureReason,
        equals(PrayerLocationFailureReason.platformFailure),
      );
      expect(
        platformResult.errorMessage,
        contains('Native location provider error'),
      );
    });

    test(
      'returns permissionDenied without prompting when requestPermissionIfNeeded is false and permission is denied',
      () async {
        final fakeClient = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.denied,
          requestedPermission: LocationPermission.whileInUse,
        );
        final service = PrayerLocationService(client: fakeClient);

        final result = await service.getCurrentLocation(
          requestPermissionIfNeeded: false,
        );

        expect(result.isFailure, isTrue);
        expect(result.coordinates, isNull);
        expect(
          result.failureReason,
          equals(PrayerLocationFailureReason.permissionDenied),
        );
        expect(fakeClient.isServiceEnabledCalls, equals(1));
        expect(fakeClient.checkPermissionCalls, equals(1));
        // Must not call requestPermission when requestPermissionIfNeeded is false
        expect(fakeClient.requestPermissionCalls, equals(0));
        expect(fakeClient.getCurrentPositionCalls, equals(0));
      },
    );

    test(
      'maps invalid coordinates (NaN, infinity, out-of-range) from geolocator Position to positionUnavailable',
      () async {
        final invalidPositions = <Position>[
          Position(
            latitude: double.nan,
            longitude: 39.8262,
            timestamp: DateTime.utc(2026, 3, 20),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          ),
          Position(
            latitude: 21.4225,
            longitude: double.infinity,
            timestamp: DateTime.utc(2026, 3, 20),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          ),
          Position(
            latitude: 95.0,
            longitude: 39.8262,
            timestamp: DateTime.utc(2026, 3, 20),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          ),
          Position(
            latitude: 21.4225,
            longitude: -185.0,
            timestamp: DateTime.utc(2026, 3, 20),
            accuracy: 10.0,
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          ),
        ];

        for (final invalidPos in invalidPositions) {
          final client = _FakeGeolocatorClient(
            serviceEnabled: true,
            initialPermission: LocationPermission.whileInUse,
            positionToReturn: invalidPos,
          );
          final service = PrayerLocationService(client: client);
          final result = await service.getCurrentLocation();

          expect(result.isFailure, isTrue);
          expect(result.coordinates, isNull);
          expect(
            result.failureReason,
            equals(PrayerLocationFailureReason.positionUnavailable),
          );
        }
      },
    );
  });

  group('Android Bounded Location Fallback Tests', () {
    final DateTime fixedNowUtc = DateTime.utc(2026, 3, 20, 12, 0);

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test(
      '1. Fresh location succeeds on Android without attempting LocationManager or last-known fallback',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final fakeClient = _FakeGeolocatorClient();
        final service = PrayerLocationService(
          client: fakeClient,
          clock: () => fixedNowUtc,
        );

        final result = await service.getCurrentLocation();

        expect(result.isSuccess, isTrue);
        expect(result.isCached, isFalse);
        expect(result.coordinates!.isCached, isFalse);
        expect(fakeClient.getCurrentPositionCalls, equals(1));
        expect(fakeClient.getLastKnownCalls, equals(0));
      },
    );

    test(
      '2 & 3. Fresh location timeout on Android attempts AndroidSettings(forceLocationManager: true) fallback and succeeds',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final fakeClient = _FakeGeolocatorClient(
          getPositionHandler: (settings, callIndex) async {
            if (callIndex == 1) {
              throw TimeoutException('Primary FusedLocation timed out');
            }
            return _buildPos(
              24.7136,
              46.6753,
              timestamp: fixedNowUtc,
              accuracy: 45.0,
            );
          },
        );
        final service = PrayerLocationService(
          client: fakeClient,
          clock: () => fixedNowUtc,
        );

        final result = await service.getCurrentLocation();

        expect(result.isSuccess, isTrue);
        expect(result.isCached, isFalse);
        expect(result.coordinates!.latitude, equals(24.7136));
        expect(result.coordinates!.longitude, equals(46.6753));
        expect(fakeClient.getCurrentPositionCalls, equals(2));
        expect(fakeClient.getLastKnownCalls, equals(0));

        final fallbackSettings = fakeClient.recordedLocationSettings[1];
        expect(fallbackSettings, isA<AndroidSettings>());
        final androidSettings = fallbackSettings as AndroidSettings;
        expect(androidSettings.forceLocationManager, isTrue);
        expect(
          androidSettings.accuracy,
          equals(PrayerLocationService.defaultFallbackAccuracy),
        );
        expect(
          androidSettings.timeLimit,
          equals(PrayerLocationService.defaultFallbackTimeout),
        );
      },
    );

    test(
      '4. When both fresh attempts fail on Android, prefers most recent valid cached last-known position (<= 24h) and marks isCached',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final olderRecent = _buildPos(
          21.4000,
          39.8000,
          timestamp: fixedNowUtc.subtract(const Duration(hours: 6)),
        );
        final newerRecent = _buildPos(
          21.4225,
          39.8262,
          timestamp: fixedNowUtc.subtract(const Duration(minutes: 20)),
        );

        final fakeClient = _FakeGeolocatorClient(
          errorToThrowOnGetPosition: TimeoutException('Fresh timeout'),
          getLastKnownHandler: (forceManager) async =>
              forceManager ? newerRecent : olderRecent,
        );
        final service = PrayerLocationService(
          client: fakeClient,
          clock: () => fixedNowUtc,
        );

        final result = await service.getCurrentLocation();

        expect(result.isSuccess, isTrue);
        expect(result.isCached, isTrue);
        expect(result.coordinates!.isCached, isTrue);
        expect(result.coordinates!.latitude, equals(21.4225));
        expect(result.coordinates!.longitude, equals(39.8262));
        expect(fakeClient.getCurrentPositionCalls, equals(2));
        expect(fakeClient.getLastKnownCalls, equals(2));
        expect(
          fakeClient.recordedLastKnownForceFlags,
          equals(const <bool>[false, true]),
        );
      },
    );

    test(
      '5 & 6. Rejects last-known positions older than 24h, invalid timestamps, and invalid coordinates',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final stalePos = _buildPos(
          21.4225,
          39.8262,
          timestamp: fixedNowUtc.subtract(
            const Duration(hours: 24, minutes: 1),
          ),
        );
        final pre2000Pos = _buildPos(
          21.4225,
          39.8262,
          timestamp: DateTime.utc(1970, 1, 1),
        );
        final invalidCoordsPos = _buildPos(
          double.nan,
          39.8262,
          timestamp: fixedNowUtc.subtract(const Duration(minutes: 5)),
        );

        for (final badCached in <Position>[
          stalePos,
          pre2000Pos,
          invalidCoordsPos,
        ]) {
          final fakeClient = _FakeGeolocatorClient(
            errorToThrowOnGetPosition: TimeoutException('Fresh timeout'),
            getLastKnownHandler: (_) async => badCached,
          );
          final service = PrayerLocationService(
            client: fakeClient,
            clock: () => fixedNowUtc,
          );

          final result = await service.getCurrentLocation();
          expect(result.isFailure, isTrue);
          expect(
            result.failureReason,
            equals(PrayerLocationFailureReason.timeout),
          );
          expect(result.coordinates, isNull);
        }
      },
    );

    test(
      '7 & 8. Permission denied and GPS disabled never invoke LocationManager fallback or last-known cache',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final cached = _buildPos(
          21.4225,
          39.8262,
          timestamp: fixedNowUtc.subtract(const Duration(minutes: 5)),
        );

        // Permission denied before position request
        final deniedClient = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.denied,
          requestedPermission: LocationPermission.denied,
          getLastKnownHandler: (_) async => cached,
        );
        final deniedResult = await PrayerLocationService(
          client: deniedClient,
          clock: () => fixedNowUtc,
        ).getCurrentLocation();
        expect(
          deniedResult.failureReason,
          equals(PrayerLocationFailureReason.permissionDenied),
        );
        expect(deniedClient.getCurrentPositionCalls, equals(0));
        expect(deniedClient.getLastKnownCalls, equals(0));

        // GPS disabled mid-request (Attempt 1 throws LocationServiceDisabledException)
        final gpsDisabledClient = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.whileInUse,
          errorToThrowOnGetPosition: const LocationServiceDisabledException(),
          getLastKnownHandler: (_) async => cached,
        );
        final gpsResult = await PrayerLocationService(
          client: gpsDisabledClient,
          clock: () => fixedNowUtc,
        ).getCurrentLocation();
        expect(
          gpsResult.failureReason,
          equals(PrayerLocationFailureReason.serviceDisabled),
        );
        expect(gpsDisabledClient.getCurrentPositionCalls, equals(1));
        expect(gpsDisabledClient.getLastKnownCalls, equals(0));

        // Permission denied mid-request (Attempt 1 throws PermissionDeniedException)
        final permMidClient = _FakeGeolocatorClient(
          serviceEnabled: true,
          initialPermission: LocationPermission.whileInUse,
          errorToThrowOnGetPosition: const PermissionDeniedException('Denied'),
          getLastKnownHandler: (_) async => cached,
        );
        final permMidResult = await PrayerLocationService(
          client: permMidClient,
          clock: () => fixedNowUtc,
        ).getCurrentLocation();
        expect(
          permMidResult.failureReason,
          equals(PrayerLocationFailureReason.permissionDenied),
        );
        expect(permMidClient.getCurrentPositionCalls, equals(1));
        expect(permMidClient.getLastKnownCalls, equals(0));
      },
    );

    test(
      '9. Non-Android behavior remains unchanged (no LocationManager or last-known fallback on iOS)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final recentCached = _buildPos(
          21.4225,
          39.8262,
          timestamp: fixedNowUtc.subtract(const Duration(minutes: 5)),
        );
        final fakeClient = _FakeGeolocatorClient(
          errorToThrowOnGetPosition: TimeoutException('iOS timeout'),
          getLastKnownHandler: (_) async => recentCached,
        );
        final service = PrayerLocationService(
          client: fakeClient,
          clock: () => fixedNowUtc,
        );

        final result = await service.getCurrentLocation();

        expect(result.isFailure, isTrue);
        expect(
          result.failureReason,
          equals(PrayerLocationFailureReason.timeout),
        );
        expect(fakeClient.getCurrentPositionCalls, equals(1));
        expect(fakeClient.getLastKnownCalls, equals(0));
        expect(fakeClient.recordedLocationSettings.single, isNot(isA<AndroidSettings>()));
      },
    );

    test(
      '11. Hung preflight, fresh, fallback, and cache calls all terminate within bounded timeouts',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        // Hung isLocationServiceEnabled terminates within preflightTimeout
        final hungServiceCheckClient = _FakeGeolocatorClient(
          serviceEnabledHandler: () => Completer<bool>().future,
        );
        final service1 = PrayerLocationService(
          client: hungServiceCheckClient,
          preflightTimeout: const Duration(milliseconds: 20),
        );
        final res1 = await service1.getCurrentLocation();
        expect(res1.failureReason, equals(PrayerLocationFailureReason.timeout));
        expect(hungServiceCheckClient.getCurrentPositionCalls, equals(0));

        // Hung checkPermission terminates within preflightTimeout
        final hungPermCheckClient = _FakeGeolocatorClient(
          checkPermissionHandler: () => Completer<LocationPermission>().future,
        );
        final servicePerm = PrayerLocationService(
          client: hungPermCheckClient,
          preflightTimeout: const Duration(milliseconds: 20),
        );
        final resPerm = await servicePerm.getCurrentLocation();
        expect(resPerm.failureReason, equals(PrayerLocationFailureReason.timeout));
        expect(hungPermCheckClient.getCurrentPositionCalls, equals(0));

        // Hung getCurrentPosition Attempt 1 + Attempt 2 + hung getLastKnownPosition
        final hungAllClient = _FakeGeolocatorClient(
          getPositionHandler: (_, _) => Completer<Position>().future,
          getLastKnownHandler: (_) => Completer<Position?>().future,
        );
        final service2 = PrayerLocationService(
          client: hungAllClient,
          timeout: const Duration(milliseconds: 20),
          fallbackTimeout: const Duration(milliseconds: 20),
          lastKnownQueryTimeout: const Duration(milliseconds: 20),
        );
        final res2 = await service2.getCurrentLocation();
        expect(res2.failureReason, equals(PrayerLocationFailureReason.timeout));
        expect(hungAllClient.getCurrentPositionCalls, equals(2));
        expect(hungAllClient.getLastKnownCalls, equals(2));
      },
    );
  });
}

