import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'qibla_calculation_service.dart';

/// North reference frame of a device heading reported by [QiblaCompassService].
enum QiblaHeadingReference {
  /// Heading is measured clockwise from Magnetic North (Android sensors).
  /// Requires local geomagnetic declination correction to convert to True North.
  magneticNorth,

  /// Heading is already measured clockwise from Geographic True North
  /// (iOS `CLHeading.trueHeading`). Must NOT receive additional declination correction.
  trueNorth,
}

/// Immutable, normalized snapshot of a compass sensor reading.
@immutable
class QiblaCompassReading {
  /// Normalized device heading in `[0.0, 360.0)` within [headingReference], or
  /// `null` when the platform event reported an invalid/unavailable heading
  /// (such as iOS `trueHeading == -1.0` or null sensor events).
  final double? heading;

  /// Reference north frame for [heading] ([QiblaHeadingReference.magneticNorth]
  /// on Android, [QiblaHeadingReference.trueNorth] on iOS).
  final QiblaHeadingReference headingReference;

  /// Platform-reported accuracy deviation in degrees, or `null` when unknown.
  /// On Android `flutter_compass`, values >= 35 correspond to low/unreliable
  /// accuracy where calibration is recommended.
  final double? accuracy;

  /// Whether calibration guidance should be surfaced to the user.
  final bool needsCalibration;

  bool get hasValidHeading => heading != null && heading!.isFinite;

  bool get isTrueNorth => headingReference == QiblaHeadingReference.trueNorth;

  const QiblaCompassReading({
    required this.heading,
    required this.headingReference,
    this.accuracy,
    this.needsCalibration = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QiblaCompassReading &&
        other.heading == heading &&
        other.headingReference == headingReference &&
        other.accuracy == accuracy &&
        other.needsCalibration == needsCalibration;
  }

  @override
  int get hashCode =>
      Object.hash(heading, headingReference, accuracy, needsCalibration);
}

/// Injectable abstraction over `flutter_compass` so compass tests can inject
/// deterministic streams without real magnetometer hardware.
abstract class CompassSensorClient {
  /// Returns the platform's compass stream, or `null` when unavailable.
  Stream<CompassEvent>? get events;
}

/// Production [CompassSensorClient] delegating directly to [FlutterCompass.events].
class FlutterCompassSensorClient implements CompassSensorClient {
  const FlutterCompassSensorClient();

  @override
  Stream<CompassEvent>? get events {
    try {
      return FlutterCompass.events;
    } catch (_) {
      return null;
    }
  }
}

/// Wraps [CompassSensorClient] to expose normalized, null-safe
/// [QiblaCompassReading] events with explicit north-reference metadata
/// ([QiblaHeadingReference.magneticNorth] on Android,
/// [QiblaHeadingReference.trueNorth] on iOS).
class QiblaCompassService {
  /// Accuracy threshold at or above which Android/iOS compass readings indicate
  /// low precision / need for figure-8 calibration.
  static const double calibrationAccuracyThreshold = 35.0;

  final CompassSensorClient _client;
  final TargetPlatform? _platformOverride;
  final QiblaHeadingReference? _headingReferenceOverride;

  const QiblaCompassService({
    CompassSensorClient? client,
    TargetPlatform? platform,
    QiblaHeadingReference? headingReference,
  }) : _client = client ?? const FlutterCompassSensorClient(),
       _platformOverride = platform,
       _headingReferenceOverride = headingReference;

  TargetPlatform get _effectivePlatform =>
      _platformOverride ?? defaultTargetPlatform;

  /// Resolves the heading reference frame for the active platform:
  /// - Android (`TargetPlatform.android`): [QiblaHeadingReference.magneticNorth]
  /// - iOS (`TargetPlatform.iOS`): [QiblaHeadingReference.trueNorth]
  QiblaHeadingReference get headingReference {
    if (_headingReferenceOverride != null) {
      return _headingReferenceOverride;
    }
    if (!kIsWeb && _effectivePlatform == TargetPlatform.iOS) {
      return QiblaHeadingReference.trueNorth;
    }
    return QiblaHeadingReference.magneticNorth;
  }

  /// Returns a stream of normalized [QiblaCompassReading] events, or `null`
  /// if no compass stream is exposed by the platform.
  Stream<QiblaCompassReading>? readings() {
    final Stream<CompassEvent>? source = _client.events;
    if (source == null) {
      return null;
    }
    final QiblaHeadingReference reference = headingReference;
    return source.map((event) => _mapEvent(event, reference));
  }

  static QiblaCompassReading _mapEvent(
    CompassEvent event,
    QiblaHeadingReference reference,
  ) {
    final double? rawHeading = event.heading;

    // On iOS, `CLLocationManager.didUpdateHeading` sends `trueHeading = -1.0`
    // (or < 0) when CoreLocation cannot compute True North.
    // On Android, `SensorManager.getOrientation` legitimately emits negative
    // azimuths in [-180, 0) which represent valid Magnetic North headings.
    final bool isValidHeading =
        rawHeading != null &&
        rawHeading.isFinite &&
        (reference != QiblaHeadingReference.trueNorth || rawHeading >= 0.0);

    final double? normalizedHeading = isValidHeading
        ? QiblaCalculationService.normalizeAngle(rawHeading)
        : null;

    final double? accuracy =
        (event.accuracy != null &&
            event.accuracy!.isFinite &&
            event.accuracy! >= 0)
        ? event.accuracy
        : null;

    final bool needsCalibration =
        accuracy != null && accuracy >= calibrationAccuracyThreshold;

    return QiblaCompassReading(
      heading: normalizedHeading,
      headingReference: reference,
      accuracy: accuracy,
      needsCalibration: needsCalibration,
    );
  }
}
