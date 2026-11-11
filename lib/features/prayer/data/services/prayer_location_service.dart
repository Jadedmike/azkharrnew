import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// Typed reasons why a foreground device-location request can fail.
enum PrayerLocationFailureReason {
  /// Device-wide location services (GPS / network location) are turned off.
  serviceDisabled,

  /// Foreground location permission was denied by the user.
  permissionDenied,

  /// Foreground location permission is permanently denied and must be enabled
  /// in system settings.
  permissionDeniedForever,

  /// Location retrieval timed out before a fix could be acquired.
  timeout,

  /// The platform could not determine a valid position (e.g., no fix available
  /// or invalid coordinates returned).
  positionUnavailable,

  /// An unexpected platform, configuration, or runtime exception occurred.
  platformFailure,
}

/// Immutable value object representing a single foreground geographic coordinate
/// fix.
@immutable
class PrayerCoordinates {
  /// Latitude in degrees (`-90.0` to `90.0`).
  final double latitude;

  /// Longitude in degrees (`-180.0` to `180.0`).
  final double longitude;

  /// Optional horizontal accuracy in meters, if reported by the platform.
  final double? accuracy;

  /// Timestamp when the fix was recorded by the platform.
  final DateTime timestamp;

  /// Whether these coordinates came from the platform's last-known cache
  /// (`true`) rather than a fresh foreground fix (`false`).
  final bool isCached;

  const PrayerCoordinates({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.isCached = false,
  });

  /// Returns `true` if [latitude] and [longitude] are finite and within valid
  /// geographic ranges.
  bool get isValid =>
      latitude.isFinite &&
      latitude >= -90.0 &&
      latitude <= 90.0 &&
      longitude.isFinite &&
      longitude >= -180.0 &&
      longitude <= 180.0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerCoordinates &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.accuracy == accuracy &&
        other.timestamp == timestamp &&
        other.isCached == isCached;
  }

  @override
  int get hashCode =>
      Object.hash(latitude, longitude, accuracy, timestamp, isCached);

  @override
  String toString() {
    return 'PrayerCoordinates('
        'latitude: $latitude, '
        'longitude: $longitude, '
        'accuracy: $accuracy, '
        'timestamp: $timestamp, '
        'isCached: $isCached'
        ')';
  }
}

/// Structured, immutable result of a foreground location request.
@immutable
class PrayerLocationResult {
  /// Whether a valid foreground location fix was obtained.
  final bool isSuccess;

  /// The retrieved coordinates when [isSuccess] is `true`, otherwise `null`.
  final PrayerCoordinates? coordinates;

  /// The typed failure reason when [isSuccess] is `false`, otherwise `null`.
  final PrayerLocationFailureReason? failureReason;

  /// Diagnostic message describing the failure when [isSuccess] is `false`.
  final String? errorMessage;

  /// Optional underlying exception when [isSuccess] is `false`.
  final Object? cause;

  /// Creates a successful [PrayerLocationResult].
  const PrayerLocationResult.success(PrayerCoordinates this.coordinates)
      : isSuccess = true,
        failureReason = null,
        errorMessage = null,
        cause = null;

  /// Creates a failed [PrayerLocationResult].
  const PrayerLocationResult.failure(
    PrayerLocationFailureReason this.failureReason, {
    this.errorMessage,
    this.cause,
  })  : isSuccess = false,
        coordinates = null;

  /// Convenience getter returning `true` when the location request failed.
  bool get isFailure => !isSuccess;

  /// Returns `true` when [isSuccess] is `true` and the returned coordinates
  /// came from the last-known cache rather than a fresh GPS/network fix.
  bool get isCached => coordinates?.isCached ?? false;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrayerLocationResult &&
        other.isSuccess == isSuccess &&
        other.coordinates == coordinates &&
        other.failureReason == failureReason &&
        other.errorMessage == errorMessage;
  }

  @override
  int get hashCode => Object.hash(
        isSuccess,
        coordinates,
        failureReason,
        errorMessage,
      );

  @override
  String toString() {
    if (isSuccess) {
      return 'PrayerLocationResult.success($coordinates)';
    }
    return 'PrayerLocationResult.failure('
        'reason: ${failureReason?.name}, '
        'message: $errorMessage'
        ')';
  }
}

/// Injectable abstraction over `geolocator` operations to keep
/// [PrayerLocationService] unit-testable without real GPS hardware.
abstract class GeolocatorClient {
  /// Checks whether device location services are enabled.
  Future<bool> isLocationServiceEnabled();

  /// Checks the current location permission status without prompting the user.
  Future<LocationPermission> checkPermission();

  /// Prompts the user for foreground location permission.
  Future<LocationPermission> requestPermission();

  /// Acquires a single current position fix using the provided
  /// [LocationSettings].
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  });
}

/// Optional capability interface for [GeolocatorClient] implementations that
/// expose the platform's last-known cached position.
abstract class LastKnownPositionProvider {
  /// Retrieves the most recent cached [Position] from the platform, if any.
  Future<Position?> getLastKnownPosition({
    bool forceAndroidLocationManager = false,
  });
}

/// Default production [GeolocatorClient] delegating to static [Geolocator]
/// methods.
class DefaultGeolocatorClient
    implements GeolocatorClient, LastKnownPositionProvider {
  const DefaultGeolocatorClient();

  @override
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  }) =>
      Geolocator.getCurrentPosition(locationSettings: locationSettings);

  @override
  Future<Position?> getLastKnownPosition({
    bool forceAndroidLocationManager = false,
  }) =>
      Geolocator.getLastKnownPosition(
        forceAndroidLocationManager: forceAndroidLocationManager,
      );
}

/// Foreground-only, one-shot location service for prayer time and Qibla
/// calculations.
///
/// ### Acquisition Strategy
/// - **Attempt 1 (All platforms):** Requests a fresh foreground position with
///   [timeout] (15s default) and [accuracy] (`LocationAccuracy.medium`).
/// - **Attempt 2 (Android only fallback):** If Attempt 1 times out or hits a
///   recoverable provider failure on Android, retries using [AndroidSettings]
///   with `forceLocationManager: true`, [fallbackAccuracy] (`low`), and
///   [fallbackTimeout] (12s default).
/// - **Attempt 3 (Android last-known fallback):** If both fresh attempts fail
///   on Android, checks `getLastKnownPosition` (both standard and
///   `LocationManager`), accepting only valid coordinates whose timestamp is
///   no older than [lastKnownMaxAge] (24 hours) and marking the returned
///   [PrayerCoordinates.isCached] as `true`.
///
/// Permission denials and disabled location services never trigger fallbacks or
/// cached bypasses.
class PrayerLocationService {
  /// Default timeout for the primary fresh position attempt.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Default timeout for the Android `LocationManager` fallback attempt.
  static const Duration defaultFallbackTimeout = Duration(seconds: 12);

  /// Bounded timeout for non-interactive preflight checks (`isLocationServiceEnabled`
  /// and `checkPermission`).
  static const Duration defaultPreflightTimeout = Duration(seconds: 5);

  /// Bounded timeout for reading cached last-known positions.
  static const Duration defaultLastKnownQueryTimeout = Duration(seconds: 5);

  /// Maximum accepted age for a cached last-known position fallback.
  static const Duration defaultLastKnownMaxAge = Duration(hours: 24);

  /// Allowed forward clock skew when validating cached position timestamps.
  static const Duration maxFutureTimestampSkew = Duration(minutes: 5);

  /// Default accuracy level for primary acquisition.
  static const LocationAccuracy defaultAccuracy = LocationAccuracy.medium;

  /// Default accuracy level for Android `LocationManager` fallback.
  static const LocationAccuracy defaultFallbackAccuracy = LocationAccuracy.low;

  final GeolocatorClient _client;
  final Duration timeout;
  final Duration fallbackTimeout;
  final Duration preflightTimeout;
  final Duration lastKnownQueryTimeout;
  final Duration lastKnownMaxAge;
  final LocationAccuracy accuracy;
  final LocationAccuracy fallbackAccuracy;
  final DateTime Function()? _clock;

  /// Creates a [PrayerLocationService].
  ///
  /// Does not trigger any location or permission requests during initialization.
  const PrayerLocationService({
    GeolocatorClient? client,
    this.timeout = defaultTimeout,
    this.fallbackTimeout = defaultFallbackTimeout,
    this.preflightTimeout = defaultPreflightTimeout,
    this.lastKnownQueryTimeout = defaultLastKnownQueryTimeout,
    this.lastKnownMaxAge = defaultLastKnownMaxAge,
    this.accuracy = defaultAccuracy,
    this.fallbackAccuracy = defaultFallbackAccuracy,
    DateTime Function()? clock,
  })  : _client = client ?? const DefaultGeolocatorClient(),
        _clock = clock;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  DateTime _nowUtc() => (_clock?.call() ?? DateTime.now()).toUtc();

  /// Returns `true` if [permission] grants foreground access to device
  /// location.
  static bool isPermissionGranted(LocationPermission permission) {
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Checks whether location services are enabled and foreground permission is
  /// currently granted without prompting the user.
  Future<bool> hasGrantedForegroundAccess() async {
    try {
      final serviceEnabled =
          await _client.isLocationServiceEnabled().timeout(preflightTimeout);
      if (!serviceEnabled) {
        return false;
      }
      final permission =
          await _client.checkPermission().timeout(preflightTimeout);
      return isPermissionGranted(permission);
    } catch (_) {
      return false;
    }
  }

  /// Requests a single foreground location fix on demand.
  Future<PrayerLocationResult> getCurrentLocation({
    bool requestPermissionIfNeeded = true,
  }) async {
    try {
      final bool serviceEnabled =
          await _client.isLocationServiceEnabled().timeout(preflightTimeout);
      if (!serviceEnabled) {
        return const PrayerLocationResult.failure(
          PrayerLocationFailureReason.serviceDisabled,
          errorMessage: 'Location services are disabled on this device.',
        );
      }

      LocationPermission permission =
          await _client.checkPermission().timeout(preflightTimeout);

      if (permission == LocationPermission.deniedForever) {
        return const PrayerLocationResult.failure(
          PrayerLocationFailureReason.permissionDeniedForever,
          errorMessage:
              'Location permission is permanently denied. Enable it in app settings.',
        );
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        if (!requestPermissionIfNeeded) {
          return const PrayerLocationResult.failure(
            PrayerLocationFailureReason.permissionDenied,
            errorMessage: 'Location permission has not been granted.',
          );
        }

        // Never impose a short timeout on the user's interactive OS permission dialog.
        permission = await _client.requestPermission();

        if (permission == LocationPermission.deniedForever) {
          return const PrayerLocationResult.failure(
            PrayerLocationFailureReason.permissionDeniedForever,
            errorMessage:
                'Location permission is permanently denied. Enable it in app settings.',
          );
        }

        if (!isPermissionGranted(permission)) {
          return const PrayerLocationResult.failure(
            PrayerLocationFailureReason.permissionDenied,
            errorMessage: 'Location permission was denied by the user.',
          );
        }
      }

      // Attempt 1: Standard foreground fresh position
      final attempt1 = await _tryAcquireFreshPosition(
        LocationSettings(accuracy: accuracy, timeLimit: timeout),
        timeout,
      );
      if (attempt1.result != null) {
        return attempt1.result!;
      }

      // Preserve non-Android behavior: only Attempt 1 executes outside Android.
      if (!_isAndroid) {
        return attempt1.failure!;
      }

      PrayerLocationResult finalFailure = attempt1.failure!;

      // Attempt 2 (Android only): LocationManager fallback for stalled GMS / FusedLocation
      final attempt2 = await _tryAcquireFreshPosition(
        AndroidSettings(
          accuracy: fallbackAccuracy,
          forceLocationManager: true,
          timeLimit: fallbackTimeout,
        ),
        fallbackTimeout,
      );
      if (attempt2.result != null) {
        return attempt2.result!;
      }
      if (attempt2.nonRecoverable) {
        return attempt2.failure!;
      }
      // Keep the more specific failure reason if Attempt 1 was a generic timeout
      if (finalFailure.failureReason != PrayerLocationFailureReason.timeout &&
          attempt2.failure != null) {
        finalFailure = attempt2.failure!;
      }

      // Attempt 3 (Android only): Recent cached last-known position (<= 24h)
      final cachedAttempt = await _tryLastKnownPositionFallback();
      if (cachedAttempt.nonRecoverableFailure != null) {
        return cachedAttempt.nonRecoverableFailure!;
      }
      if (cachedAttempt.coordinates != null) {
        return PrayerLocationResult.success(cachedAttempt.coordinates!);
      }

      return finalFailure;
    } on TimeoutException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.timeout,
        errorMessage: 'Timed out while checking device location state.',
        cause: error,
      );
    } on LocationServiceDisabledException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.serviceDisabled,
        errorMessage: 'Location services are disabled on this device.',
        cause: error,
      );
    } on PermissionDeniedException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.permissionDenied,
        errorMessage: 'Location permission was denied by the platform.',
        cause: error,
      );
    } on PermissionDefinitionsNotFoundException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage:
            'Missing platform location permission definitions in app manifest.',
        cause: error,
      );
    } on PermissionRequestInProgressException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage: 'A location permission request is already in progress.',
        cause: error,
      );
    } on PlatformException catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage:
            error.message ?? 'A platform exception occurred while getting location.',
        cause: error,
      );
    } catch (error) {
      return PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage: 'An unexpected error occurred while getting location.',
        cause: error,
      );
    }
  }

  Future<({
    PrayerLocationResult? result,
    PrayerLocationResult? failure,
    bool nonRecoverable,
  })> _tryAcquireFreshPosition(
    LocationSettings settings,
    Duration requestTimeout,
  ) async {
    try {
      final Position position = await _client
          .getCurrentPosition(locationSettings: settings)
          .timeout(requestTimeout);

      final coordinates = PrayerCoordinates(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.hasAccuracy ? position.accuracy : null,
        timestamp: position.timestamp,
        isCached: false,
      );

      if (!coordinates.isValid) {
        return (
          result: null,
          failure: const PrayerLocationResult.failure(
            PrayerLocationFailureReason.positionUnavailable,
            errorMessage:
                'Received invalid geographic coordinates from the platform.',
          ),
          nonRecoverable: false,
        );
      }

      return (
        result: PrayerLocationResult.success(coordinates),
        failure: null,
        nonRecoverable: false,
      );
    } on TimeoutException catch (error) {
      return (
        result: null,
        failure: PrayerLocationResult.failure(
          PrayerLocationFailureReason.timeout,
          errorMessage: 'Timed out while waiting for a device location fix.',
          cause: error,
        ),
        nonRecoverable: false,
      );
    } on LocationServiceDisabledException catch (error) {
      final failure = PrayerLocationResult.failure(
        PrayerLocationFailureReason.serviceDisabled,
        errorMessage: 'Location services were disabled during the request.',
        cause: error,
      );
      return (result: failure, failure: failure, nonRecoverable: true);
    } on PermissionDeniedException catch (error) {
      final failure = PrayerLocationResult.failure(
        PrayerLocationFailureReason.permissionDenied,
        errorMessage: 'Location permission was denied by the platform.',
        cause: error,
      );
      return (result: failure, failure: failure, nonRecoverable: true);
    } on PositionUpdateException catch (error) {
      return (
        result: null,
        failure: PrayerLocationResult.failure(
          PrayerLocationFailureReason.positionUnavailable,
          errorMessage: 'Unable to determine the current device position.',
          cause: error,
        ),
        nonRecoverable: false,
      );
    } on PermissionDefinitionsNotFoundException catch (error) {
      final failure = PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage:
            'Missing platform location permission definitions in app manifest.',
        cause: error,
      );
      return (result: failure, failure: failure, nonRecoverable: true);
    } on PermissionRequestInProgressException catch (error) {
      final failure = PrayerLocationResult.failure(
        PrayerLocationFailureReason.platformFailure,
        errorMessage: 'A location permission request is already in progress.',
        cause: error,
      );
      return (result: failure, failure: failure, nonRecoverable: true);
    } on PlatformException catch (error) {
      return (
        result: null,
        failure: PrayerLocationResult.failure(
          PrayerLocationFailureReason.platformFailure,
          errorMessage:
              error.message ??
              'A platform exception occurred while getting location.',
          cause: error,
        ),
        nonRecoverable: false,
      );
    }
  }

  Future<({
    PrayerCoordinates? coordinates,
    PrayerLocationResult? nonRecoverableFailure,
  })> _tryLastKnownPositionFallback() async {
    if (_client is! LastKnownPositionProvider) {
      return (coordinates: null, nonRecoverableFailure: null);
    }

    final provider = _client as LastKnownPositionProvider;
    final candidates = <Position>[];

    for (final forceManager in const <bool>[false, true]) {
      try {
        final pos = await provider
            .getLastKnownPosition(forceAndroidLocationManager: forceManager)
            .timeout(lastKnownQueryTimeout);
        if (pos != null) {
          candidates.add(pos);
        }
      } on LocationServiceDisabledException catch (error) {
        return (
          coordinates: null,
          nonRecoverableFailure: PrayerLocationResult.failure(
            PrayerLocationFailureReason.serviceDisabled,
            errorMessage: 'Location services were disabled during the request.',
            cause: error,
          ),
        );
      } on PermissionDeniedException catch (error) {
        return (
          coordinates: null,
          nonRecoverableFailure: PrayerLocationResult.failure(
            PrayerLocationFailureReason.permissionDenied,
            errorMessage: 'Location permission was denied by the platform.',
            cause: error,
          ),
        );
      } on TimeoutException {
        // Ignore single cache query timeout and continue checking remaining cache
      } on PlatformException {
        // Recoverable provider cache read failure
      }
    }

    final DateTime nowUtc = _nowUtc();
    PrayerCoordinates? bestCached;

    for (final pos in candidates) {
      final coords = PrayerCoordinates(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.hasAccuracy ? pos.accuracy : null,
        timestamp: pos.timestamp,
        isCached: true,
      );
      if (!coords.isValid) {
        continue;
      }
      if (!_isAcceptableCachedTimestamp(pos.timestamp, nowUtc)) {
        continue;
      }
      if (bestCached == null ||
          coords.timestamp.toUtc().isAfter(bestCached.timestamp.toUtc())) {
        bestCached = coords;
      }
    }

    return (coordinates: bestCached, nonRecoverableFailure: null);
  }

  bool _isAcceptableCachedTimestamp(DateTime timestamp, DateTime nowUtc) {
    final DateTime tsUtc = timestamp.toUtc();
    if (tsUtc.year < 2000) {
      return false;
    }
    if (tsUtc.isAfter(nowUtc.add(maxFutureTimestampSkew))) {
      return false;
    }
    final Duration age = nowUtc.difference(tsUtc);
    return age <= lastKnownMaxAge;
  }
}
