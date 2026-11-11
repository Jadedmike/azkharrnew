import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adhkar/features/qibla/data/services/qibla_compass_service.dart';

class _FakeCompassSensorClient implements CompassSensorClient {
  final Stream<CompassEvent>? _stream;

  _FakeCompassSensorClient(this._stream);

  @override
  Stream<CompassEvent>? get events => _stream;
}

void main() {
  group('QiblaCompassService', () {
    test('returns null stream when underlying compass client returns null', () {
      final service = QiblaCompassService(
        client: _FakeCompassSensorClient(null),
      );

      expect(service.readings(), isNull);
    });

    test('identifies Magnetic North on Android and accepts valid negative headings', () async {
      final controller = StreamController<CompassEvent>();
      addTearDown(controller.close);

      final service = QiblaCompassService(
        client: _FakeCompassSensorClient(controller.stream),
        platform: TargetPlatform.android,
      );
      expect(service.headingReference, QiblaHeadingReference.magneticNorth);

      final emitted = <QiblaCompassReading>[];
      final sub = service.readings()!.listen(emitted.add);
      addTearDown(sub.cancel);

      controller.add(CompassEvent.fromList(<double>[-90.0, 0.0, 15.0]));
      controller.add(CompassEvent.fromList(<double>[-1.0, 0.0, 15.0]));
      controller.add(CompassEvent.fromList(<double>[450.0, 0.0, 45.0]));
      controller.add(CompassEvent.fromList(<double>[180.0, 0.0, -1.0]));
      controller.add(CompassEvent.fromList(null));

      await pumpEventQueue();

      expect(emitted.length, 5);

      expect(emitted[0].heading, 270.0);
      expect(emitted[0].headingReference, QiblaHeadingReference.magneticNorth);
      expect(emitted[0].isTrueNorth, isFalse);
      expect(emitted[0].accuracy, 15.0);
      expect(emitted[0].needsCalibration, isFalse);
      expect(emitted[0].hasValidHeading, isTrue);

      // -1.0 on Android is a valid magnetic azimuth (359 deg), NOT rejected
      expect(emitted[1].heading, 359.0);
      expect(emitted[1].hasValidHeading, isTrue);

      expect(emitted[2].heading, 90.0);
      expect(emitted[2].accuracy, 45.0);
      expect(emitted[2].needsCalibration, isTrue);
      expect(emitted[2].hasValidHeading, isTrue);

      expect(emitted[3].heading, 180.0);
      expect(emitted[3].accuracy, isNull);
      expect(emitted[3].needsCalibration, isFalse);

      expect(emitted[4].heading, isNull);
      expect(emitted[4].hasValidHeading, isFalse);
    });

    test('identifies True North on iOS and rejects -1.0 invalid sentinel', () async {
      final controller = StreamController<CompassEvent>();
      addTearDown(controller.close);

      final service = QiblaCompassService(
        client: _FakeCompassSensorClient(controller.stream),
        platform: TargetPlatform.iOS,
      );
      expect(service.headingReference, QiblaHeadingReference.trueNorth);

      final emitted = <QiblaCompassReading>[];
      final sub = service.readings()!.listen(emitted.add);
      addTearDown(sub.cancel);

      controller.add(CompassEvent.fromList(<double>[-1.0, 0.0, 10.0]));
      controller.add(CompassEvent.fromList(<double>[152.5, 0.0, 10.0]));

      await pumpEventQueue();

      expect(emitted.length, 2);

      // iOS trueHeading == -1.0 is rejected as invalid
      expect(emitted[0].headingReference, QiblaHeadingReference.trueNorth);
      expect(emitted[0].isTrueNorth, isTrue);
      expect(emitted[0].heading, isNull);
      expect(emitted[0].hasValidHeading, isFalse);

      // Valid iOS trueHeading is preserved without modification
      expect(emitted[1].heading, 152.5);
      expect(emitted[1].hasValidHeading, isTrue);
    });

    test('propagates stream errors cleanly and cancels subscription on request', () async {
      bool cancelled = false;
      final controller = StreamController<CompassEvent>(
        onCancel: () {
          cancelled = true;
        },
      );

      final service = QiblaCompassService(
        client: _FakeCompassSensorClient(controller.stream),
      );

      Object? capturedError;
      final sub = service.readings()!.listen(
        (_) {},
        onError: (Object error) {
          capturedError = error;
        },
      );

      controller.addError(StateError('Magnetometer hardware error'));
      await pumpEventQueue();
      expect(capturedError, isA<StateError>());

      await sub.cancel();
      expect(cancelled, isTrue);
    });
  });
}
