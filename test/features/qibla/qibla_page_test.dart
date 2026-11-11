import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:adhkar/features/adhkar/presentation/managers/favorites_manager.dart';
import 'package:adhkar/features/adhkar/presentation/pages/home_page.dart';
import 'package:adhkar/features/prayer/data/models/saved_prayer_location.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_cache_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_location_service.dart';
import 'package:adhkar/features/qibla/data/services/magnetic_declination_service.dart';
import 'package:adhkar/features/qibla/data/services/qibla_calculation_service.dart';
import 'package:adhkar/features/qibla/data/services/qibla_compass_service.dart';
import 'package:adhkar/features/qibla/presentation/pages/qibla_page.dart';

class _TestAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('.png') ||
        key.endsWith('.jpg') ||
        key.endsWith('.jpeg') ||
        key.endsWith('.gif')) {
      return ByteData.sublistView(
        Uint8List.fromList(<int>[
          137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
          0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0,
          0, 10, 73, 68, 65, 84, 120, 156, 99, 96, 0, 0, 0, 2, 0, 1, 226,
          33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
        ]),
      );
    }
    return rootBundle.load(key);
  }
}

class _FakeGeolocatorClient implements GeolocatorClient {
  bool serviceEnabled;
  Position positionToReturn;

  int isServiceEnabledCalls = 0;
  int checkPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int getCurrentPositionCalls = 0;

  _FakeGeolocatorClient({
    this.serviceEnabled = true,
    Position? positionToReturn,
  }) : positionToReturn =
           positionToReturn ??
           Position(
             latitude: 41.0082,
             longitude: 28.9784,
             timestamp: DateTime(2026, 4, 15, 10, 0),
             accuracy: 10.0,
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
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    checkPermissionCalls++;
    return LocationPermission.whileInUse;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestPermissionCalls++;
    return LocationPermission.whileInUse;
  }

  @override
  Future<Position> getCurrentPosition({
    required LocationSettings locationSettings,
  }) async {
    getCurrentPositionCalls++;
    return positionToReturn;
  }
}

class _FakeCompassSensorClient implements CompassSensorClient {
  final Stream<CompassEvent>? _stream;

  _FakeCompassSensorClient(this._stream);

  @override
  Stream<CompassEvent>? get events => _stream;
}

class _FixedDeclinationService extends MagneticDeclinationService {
  final double? fixedDeclination;
  final MagneticDeclinationException? error;
  int calls = 0;

  _FixedDeclinationService({this.fixedDeclination, this.error});

  @override
  MagneticDeclinationResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    double altitudeKm = 0.0,
  }) {
    calls++;
    if (error != null) {
      throw error!;
    }
    return MagneticDeclinationResult(
      declinationDegrees: fixedDeclination ?? 0.0,
      decimalYear: MagneticDeclinationService.toDecimalYear(date),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FavoritesManager.favoriteDhikrs.value = <Map<String, dynamic>>[];
  });

  void setLargeSurfaceSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget wrapWithBundle(Widget child) {
    return DefaultAssetBundle(
      bundle: _TestAssetBundle(),
      child: MaterialApp(home: child),
    );
  }

  group('QiblaPage Phase 6 Widget Tests', () {
    testWidgets(
      'reuses saved location from PrayerLocationCacheService without calling GPS and displays RTL UI',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'الفاتح',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final compassController = StreamController<CompassEvent>();
        addTearDown(compassController.close);
        final compassService = QiblaCompassService(
          client: _FakeCompassSensorClient(compassController.stream),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              locationService: locationService,
              compassService: compassService,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        // Verify GPS was NEVER called automatically
        expect(fakeGeo.isServiceEnabledCalls, 0);
        expect(fakeGeo.checkPermissionCalls, 0);
        expect(fakeGeo.getCurrentPositionCalls, 0);

        // RTL directionality and Qibla header + saved readable location
        final Directionality dir = tester.widget(
          find.descendant(
            of: find.byType(QiblaPage),
            matching: find.byType(Directionality),
          ).first,
        );
        expect(dir.textDirection, TextDirection.rtl);
        expect(find.text('اتجاه القبلة'), findsOneWidget);
        expect(find.text('الموقع: تركيا، إسطنبول، الفاتح'), findsOneWidget);
        expect(find.byKey(const Key('qibla_bearing_chip')), findsOneWidget);
        expect(find.textContaining('152°'), findsOneWidget);
      },
    );

    testWidgets(
      'shows missing-location state without auto-GPS, then acquires location only when user taps button',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        final fakeGeo = _FakeGeolocatorClient();
        final locationService = PrayerLocationService(client: fakeGeo);
        final compassController = StreamController<CompassEvent>();
        addTearDown(compassController.close);
        final compassService = QiblaCompassService(
          client: _FakeCompassSensorClient(compassController.stream),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              locationService: locationService,
              compassService: compassService,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        expect(
          find.byKey(const Key('qibla_missing_location_card')),
          findsOneWidget,
        );
        expect(fakeGeo.getCurrentPositionCalls, 0);

        // User explicitly taps acquire location button
        await tester.tap(find.byKey(const Key('qibla_acquire_location_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.getCurrentPositionCalls, 1);
        expect(
          find.byKey(const Key('qibla_missing_location_card')),
          findsNothing,
        );
        // Never performs reverse geocoding: shows fallback label rather than raw coordinates
        expect(find.text('الموقع: الموقع المحفوظ'), findsOneWidget);
        expect(find.textContaining('41.00'), findsNothing);

        final persisted = await PrayerLocationCacheService().loadLocation();
        expect(persisted, isNotNull);
        expect(persisted!.latitude, closeTo(41.0082, 0.0001));
      },
    );

    testWidgets(
      'preserves previously saved valid location when explicit refresh fails',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            district: 'الفاتح',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final fakeGeo = _FakeGeolocatorClient(serviceEnabled: false);
        final locationService = PrayerLocationService(client: fakeGeo);
        final compassController = StreamController<CompassEvent>();
        addTearDown(compassController.close);
        final compassService = QiblaCompassService(
          client: _FakeCompassSensorClient(compassController.stream),
        );

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              locationService: locationService,
              compassService: compassService,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        expect(find.text('الموقع: تركيا، إسطنبول، الفاتح'), findsOneWidget);

        await tester.tap(find.byKey(const Key('qibla_refresh_location_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(fakeGeo.isServiceEnabledCalls, 1);
        expect(find.text('الموقع: تركيا، إسطنبول، الفاتح'), findsOneWidget);
        expect(
          find.text('تعذّر تحديث الموقع، تم الإبقاء على الموقع المحفوظ'),
          findsOneWidget,
        );

        final preserved = await PrayerLocationCacheService().loadLocation();
        expect(preserved!.displayName, 'تركيا، إسطنبول، الفاتح');
      },
    );

    testWidgets(
      'applies declination on Android magnetic headings, rotates dial/indicator accurately, and cancels subscription on dispose',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final fixedDate = DateTime.utc(2026, 11, 10, 12, 0);
        final declination = const MagneticDeclinationService()
            .calculate(
              latitude: 41.0082,
              longitude: 28.9784,
              date: fixedDate,
            )
            .declinationDegrees;

        bool streamCancelled = false;
        final controller = StreamController<CompassEvent>(
          onCancel: () {
            streamCancelled = true;
          },
        );
        final compassService = QiblaCompassService(
          client: _FakeCompassSensorClient(controller.stream),
          platform: TargetPlatform.android,
        );

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              locationService: PrayerLocationService(
                client: _FakeGeolocatorClient(),
              ),
              compassService: compassService,
              clock: () => fixedDate,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        // Emit valid negative Android magnetic heading (-270 == 90 deg magnetic)
        // + low accuracy triggering calibration guidance
        controller.add(CompassEvent.fromList(<double>[-270.0, 0.0, 45.0]));
        await tester.pump();
        await tester.pump();

        final double expectedTrueHeading = QiblaCalculationService.normalizeAngle(
          90.0 + declination,
        );
        final int expectedTrueDeg = QiblaCalculationService.toWholeDegrees(
          expectedTrueHeading,
        );
        expect(find.text('اتجاه الهاتف: $expectedTrueDeg°'), findsOneWidget);
        expect(find.byKey(const Key('qibla_calibration_card')), findsOneWidget);
        expect(
          find.byKey(const Key('qibla_direction_indicator')),
          findsOneWidget,
        );

        final Transform indicator = tester.widget(
          find.byKey(const Key('qibla_direction_indicator')),
        );
        const calc = QiblaCalculationService();
        final expectedBearing = calc
            .calculateBearing(latitude: 41.0082, longitude: 28.9784)
            .bearing;
        final expectedRelative = calc.calculateRelativeDirection(
          qiblaBearing: expectedBearing,
          deviceHeading: expectedTrueHeading,
        );
        final expectedAngleRad = expectedRelative * math.pi / 180.0;
        final actualZRotation = math.atan2(
          indicator.transform.entry(1, 0),
          indicator.transform.entry(0, 0),
        );
        expect(
          (actualZRotation - expectedAngleRad).abs() < 0.02 ||
              ((actualZRotation + 2 * math.pi) - expectedAngleRad).abs() < 0.02,
          isTrue,
        );

        // Emit null heading event: handled safely without crashing or resetting heading to 0
        controller.add(CompassEvent.fromList(null));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('بانتظار قراءة مستقرة من المستشعر...'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        // Dispose QiblaPage and confirm sensor subscription is cancelled
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();
        expect(streamCancelled, isTrue);
      },
    );

    testWidgets(
      'displays informative Arabic sensor-unavailable state when sensor stream is null or times out',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        // Case 1: null stream (unsupported platform/device)
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(null),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        expect(
          find.byKey(const Key('qibla_sensor_unavailable_card')),
          findsOneWidget,
        );
        expect(find.text('مستشعر البوصلة غير متوفر'), findsOneWidget);
        expect(find.byKey(const Key('qibla_direction_indicator')), findsNothing);

        // Reset tree before Case 2 so a fresh State and initState() run cleanly
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();

        // Case 2: silent stream timing out without hardware events
        final silentController = StreamController<CompassEvent>.broadcast();
        addTearDown(silentController.close);
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              key: const Key('qibla_timeout_case'),
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(silentController.stream),
              ),
              sensorAvailabilityTimeout: const Duration(milliseconds: 40),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 60));

        expect(
          find.byKey(const Key('qibla_sensor_unavailable_card')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'HomePage preserves Tasbeeh and Prayer Times entry points and navigates into QiblaPage',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        await tester.pumpWidget(wrapWithBundle(const HomePage()));
        await tester.pumpAndSettle();

        expect(find.text('المسبحة'), findsOneWidget);
        expect(find.text('مواقيت الصلاة'), findsOneWidget);
        final qiblaBtn = find.byKey(const Key('home_qibla_button'));
        expect(qiblaBtn, findsOneWidget);

        await tester.ensureVisible(qiblaBtn);
        await tester.pumpAndSettle();
        await tester.tap(qiblaBtn);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.byType(QiblaPage), findsOneWidget);
        expect(find.text('اتجاه القبلة'), findsOneWidget);
      },
    );

    testWidgets(
      'corrects Android magnetic heading with negative West, zero, and 0/360 wraparound declinations',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        // 1. Positive East (+6.0) across 357 deg magnetic -> wraps cleanly to 3 deg True
        final ctrlEast = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrlEast.close);
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              key: const Key('qibla_east_wrap'),
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrlEast.stream),
                platform: TargetPlatform.android,
              ),
              declinationService: _FixedDeclinationService(fixedDeclination: 6.0),
              clock: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        ctrlEast.add(CompassEvent.fromList(<double>[357.0, 0.0, 15.0]));
        await tester.pump();
        await tester.pump();
        expect(find.text('اتجاه الهاتف: 3°'), findsOneWidget);

        // 2. Negative West (-5.0) across 2 deg magnetic -> wraps cleanly to 357 deg True
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();
        final ctrlWest = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrlWest.close);
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              key: const Key('qibla_west_wrap'),
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrlWest.stream),
                platform: TargetPlatform.android,
              ),
              declinationService: _FixedDeclinationService(fixedDeclination: -5.0),
              clock: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        ctrlWest.add(CompassEvent.fromList(<double>[2.0, 0.0, 15.0]));
        await tester.pump();
        await tester.pump();
        expect(find.text('اتجاه الهاتف: 357°'), findsOneWidget);

        // 3. Zero declination leaves magnetic heading equal to true heading
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();
        final ctrlZero = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrlZero.close);
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              key: const Key('qibla_zero_decl'),
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrlZero.stream),
                platform: TargetPlatform.android,
              ),
              declinationService: _FixedDeclinationService(fixedDeclination: 0.0),
              clock: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        ctrlZero.add(CompassEvent.fromList(<double>[245.0, 0.0, 15.0]));
        await tester.pump();
        await tester.pump();
        expect(find.text('اتجاه الهاتف: 245°'), findsOneWidget);
      },
    );

    testWidgets(
      'iOS uses trueHeading without applying declination twice and rejects -1.0 invalid sentinel',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final ctrlIos = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrlIos.close);
        final spyDeclination = _FixedDeclinationService(fixedDeclination: 12.0);

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrlIos.stream),
                platform: TargetPlatform.iOS,
              ),
              declinationService: spyDeclination,
              clock: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        // Declination is NOT invoked on iOS because CLHeading.trueHeading is already True North
        expect(spyDeclination.calls, 0);

        // Emit iOS invalid -1.0 sentinel -> rejected cleanly
        ctrlIos.add(CompassEvent.fromList(<double>[-1.0, 0.0, 10.0]));
        await tester.pump();
        await tester.pump();
        expect(
          find.text('بانتظار قراءة مستقرة من المستشعر...'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('qibla_heading_chip')), findsNothing);

        // Emit valid iOS trueHeading -> preserved without +12 declination offset
        ctrlIos.add(CompassEvent.fromList(<double>[152.0, 0.0, 10.0]));
        await tester.pump();
        await tester.pump();
        expect(find.text('اتجاه الهاتف: 152°'), findsOneWidget);
        expect(find.text('أنت متجه نحو القبلة'), findsOneWidget);
      },
    );

    testWidgets(
      'evaluates ±5 degree alignment threshold strictly on declination-corrected True North heading',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final ctrl = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrl.close);

        const calc = QiblaCalculationService();
        final double istanbulQibla = calc
            .calculateBearing(latitude: 41.0082, longitude: 28.9784)
            .bearing; // ~151.7 deg True

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrl.stream),
                platform: TargetPlatform.android,
              ),
              declinationService: _FixedDeclinationService(fixedDeclination: 6.2),
              clock: () => DateTime.utc(2026, 11, 10),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        // Pointing at raw magnetic bearing == Qibla (151.7) puts true heading at 157.9 (> +5 deg off) -> NOT aligned
        ctrl.add(CompassEvent.fromList(<double>[istanbulQibla, 0.0, 15.0]));
        await tester.pump();
        await tester.pump();
        expect(find.text('أنت متجه نحو القبلة'), findsNothing);

        // Rotate clockwise/counter-clockwise to magnetic heading == Qibla - 6.2 -> true == 151.7 -> ALIGNED
        // Emit repeatedly to overcome smoothing filter cleanly
        final double alignedMagnetic = istanbulQibla - 6.2;
        for (int i = 0; i < 20; i++) {
          ctrl.add(CompassEvent.fromList(<double>[alignedMagnetic, 0.0, 15.0]));
          await tester.pump();
        }
        await tester.pump();
        expect(find.text('أنت متجه نحو القبلة'), findsOneWidget);
      },
    );

    testWidgets(
      'handles unsupported WMM date range explicitly without assuming zero declination',
      (WidgetTester tester) async {
        setLargeSurfaceSize(tester);
        final cacheService = PrayerLocationCacheService();
        await cacheService.saveLocation(
          SavedPrayerLocation(
            latitude: 41.0082,
            longitude: 28.9784,
            countryIsoCode: 'TR',
            countryName: 'تركيا',
            city: 'إسطنبول',
            timestamp: DateTime.utc(2026, 4, 15, 8, 0),
          ),
        );

        final ctrl = StreamController<CompassEvent>.broadcast();
        addTearDown(ctrl.close);

        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrl.stream),
                platform: TargetPlatform.android,
              ),
              // Outside WMM-2025 [2025.0, 2030.0) window
              clock: () => DateTime.utc(2032, 1, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        expect(
          find.byKey(const Key('qibla_declination_error_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('qibla_direction_indicator')),
          findsNothing,
        );
        expect(
          find.textContaining('تعذّر تصحيح الانحراف المغناطيسي'),
          findsOneWidget,
        );

        // Also verify generic calculationFailed declination exception is handled explicitly
        await tester.pumpWidget(wrapWithBundle(const SizedBox.shrink()));
        await tester.pump();
        await tester.pumpWidget(
          wrapWithBundle(
            QiblaPage(
              key: const Key('qibla_calc_fail'),
              locationCacheService: cacheService,
              compassService: QiblaCompassService(
                client: _FakeCompassSensorClient(ctrl.stream),
                platform: TargetPlatform.android,
              ),
              declinationService: _FixedDeclinationService(
                error: const MagneticDeclinationException(
                  MagneticDeclinationErrorType.calculationFailed,
                  'Non-finite geomagnetic vector',
                ),
              ),
              clock: () => DateTime.utc(2026, 6, 1),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump();

        expect(
          find.byKey(const Key('qibla_declination_error_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('qibla_direction_indicator')),
          findsNothing,
        );
      },
    );
  });
}

