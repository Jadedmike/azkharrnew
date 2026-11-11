import 'package:adhkar/main.dart' as app_main;
import 'package:adhkar/features/prayer/data/models/prayer_notification_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_settings.dart';
import 'package:adhkar/features/prayer/data/models/prayer_times_result.dart';
import 'package:adhkar/features/prayer/data/services/prayer_calculation_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_settings_service.dart';
import 'package:adhkar/features/prayer/data/services/prayer_settings_service.dart';
import 'package:adhan/adhan.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class _ScheduledRecord {
  final int id;
  final String title;
  final String body;
  final tz.TZDateTime scheduledDate;
  final NotificationDetails details;
  final AndroidScheduleMode androidScheduleMode;

  const _ScheduledRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledDate,
    required this.details,
    required this.androidScheduleMode,
  });
}

class _FakePrayerNotificationClient implements PrayerNotificationClient {
  bool permissionGranted;
  bool requestPermissionResult;
  bool exactAlarmsAllowed;
  String timezoneName;

  int isPermissionGrantedCalls = 0;
  int requestPermissionCalls = 0;
  int canScheduleExactCalls = 0;
  int openAppSettingsCalls = 0;
  final List<AndroidNotificationChannel> createdChannels =
      <AndroidNotificationChannel>[];
  final List<int> cancelledIds = <int>[];
  final Map<int, _ScheduledRecord> scheduledById = <int, _ScheduledRecord>{};

  // Seeded non-prayer pending notifications (for example, 5 Adhkar slots)
  final List<PendingNotificationRequest> nonPrayerPending =
      <PendingNotificationRequest>[
    const PendingNotificationRequest(1001, 'Morning', 'Adhkar', null),
    const PendingNotificationRequest(1002, 'Evening', 'Adhkar', null),
    const PendingNotificationRequest(2001, 'Random 1', 'Dhikr', null),
    const PendingNotificationRequest(2002, 'Random 2', 'Dhikr', null),
    const PendingNotificationRequest(2003, 'Random 3', 'Dhikr', null),
  ];

  _FakePrayerNotificationClient({
    this.permissionGranted = true,
    this.exactAlarmsAllowed = true,
    this.timezoneName = 'UTC',
  }) : requestPermissionResult = permissionGranted;

  @override
  Future<bool> isPermissionGranted() async {
    isPermissionGrantedCalls++;
    return permissionGranted;
  }

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalls++;
    permissionGranted = requestPermissionResult;
    return requestPermissionResult;
  }

  @override
  Future<bool> canScheduleExactNotifications() async {
    canScheduleExactCalls++;
    return exactAlarmsAllowed;
  }

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }

  @override
  Future<String> getLocalTimezone() async => timezoneName;

  @override
  Future<void> createAndroidChannels(
    List<AndroidNotificationChannel> channels,
  ) async {
    createdChannels.addAll(channels);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    return <PendingNotificationRequest>[
      ...nonPrayerPending,
      ...scheduledById.values.map(
        (rec) => PendingNotificationRequest(rec.id, rec.title, rec.body, null),
      ),
    ];
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
    scheduledById.remove(id);
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
  }) async {
    scheduledById[id] = _ScheduledRecord(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      details: notificationDetails,
      androidScheduleMode: androidScheduleMode,
    );
  }
}

class _ThrowingNotificationClient extends _FakePrayerNotificationClient {
  @override
  Future<bool> isPermissionGranted() async {
    throw StateError('Simulated startup notification plugin failure');
  }
}

/// Deterministic calculation service that outputs local times on `(y, m, d)`
/// (`Fajr 05:00`, `Sunrise 06:15`, `Dhuhr 12:15`, `Asr 15:30`, `Maghrib 18:15`,
/// `Isha 19:45`) shifted slightly by Madhab / Method / Coordinate sign so
/// recalculations are directly observable.
class _DeterministicCalculationService extends PrayerCalculationService {
  final List<DateTime> requestedDates = <DateTime>[];

  @override
  PrayerTimesResult calculate({
    required double latitude,
    required double longitude,
    required DateTime date,
    required PrayerSettings settings,
    String? countryCode,
    Duration? utcOffset,
  }) {
    final int y = date.year;
    final int m = date.month;
    final int d = date.day;
    requestedDates.add(DateTime(y, m, d));

    final int fajrMinuteOffset =
        settings.manualCalculationMethod == CalculationMethod.umm_al_qura
            ? 10
            : 0;
    final int asrHour = settings.madhab == Madhab.hanafi ? 16 : 15;
    final int coordShiftMinutes = latitude < 0 ? 5 : 0;

    return PrayerTimesResult(
      fajr: DateTime(y, m, d, 5, fajrMinuteOffset + coordShiftMinutes),
      sunrise: DateTime(y, m, d, 6, 15 + coordShiftMinutes),
      dhuhr: DateTime(y, m, d, 12, 15 + coordShiftMinutes),
      asr: DateTime(y, m, d, asrHour, 30 + coordShiftMinutes),
      maghrib: DateTime(y, m, d, 18, 15 + coordShiftMinutes),
      isha: DateTime(y, m, d, 19, 45 + coordShiftMinutes),
      latitude: latitude,
      longitude: longitude,
      year: y,
      month: m,
      day: d,
      calculationMode: settings.calculationMode,
      calculationMethod:
          settings.calculationMode == PrayerCalculationMode.manual
              ? settings.manualCalculationMethod
              : PrayerSettings.defaultManualCalculationMethod,
      madhab: settings.madhab,
      countryCode: countryCode,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('UTC'));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('PrayerNotificationService Unit Tests', () {
    test(
      'schedules all 5 obligatory prayers across 7 days (35 max), never schedules Sunrise, and uses IDs 5000..5069',
      () async {
        final fakeClient = _FakePrayerNotificationClient();
        final calcService = _DeterministicCalculationService();
        DateTime now = DateTime(2026, 3, 20, 4, 0); // Before all 5 prayers

        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: calcService,
          clock: () => now,
        );

        final notifSettings = PrayerNotificationSettings(enabled: true);
        const prayerSettings = PrayerSettings.defaults();

        final result = await service.reschedule(
          notificationSettings: notifSettings,
          prayerSettings: prayerSettings,
          latitude: 21.4225,
          longitude: 39.8262,
        );

        expect(result.scheduledCount, equals(35));
        expect(result.skippedDueToLimitCount, equals(0));
        expect(fakeClient.scheduledById.length, equals(35));
        expect(fakeClient.requestPermissionCalls, equals(0));

        // All IDs stay strictly inside 5000..5069
        for (final id in fakeClient.scheduledById.keys) {
          expect(id, greaterThanOrEqualTo(5000));
          expect(id, lessThanOrEqualTo(5069));
        }

        // Sunrise title/time never scheduled
        for (final record in fakeClient.scheduledById.values) {
          expect(record.title, isNot(contains('الشروق')));
          expect(record.body, isNot(contains('الشروق')));
        }

        // Total pending notifications stay well within iOS's 64 limit (5 + 35 = 40 <= 64)
        final pending = await fakeClient.pendingNotificationRequests();
        expect(pending.length, equals(40));
        expect(pending.length, lessThanOrEqualTo(64));

        // Adhkar IDs were NEVER cancelled
        for (final adhkarId in <int>[1001, 1002, 2001, 2002, 2003, 9999]) {
          expect(fakeClient.cancelledIds, isNot(contains(adhkarId)));
        }
      },
    );

    test('skips past prayer times on current day', () async {
      final fakeClient = _FakePrayerNotificationClient();
      final calcService = _DeterministicCalculationService();
      // 13:00 -> Fajr (05:00) and Dhuhr (12:15) have already passed today
      final DateTime now = DateTime(2026, 3, 20, 13, 0);

      final service = PrayerNotificationService(
        client: fakeClient,
        calculationService: calcService,
        clock: () => now,
      );

      final result = await service.reschedule(
        notificationSettings: PrayerNotificationSettings(enabled: true),
        prayerSettings: const PrayerSettings.defaults(),
        latitude: 21.4225,
        longitude: 39.8262,
      );

      // Day 0: Asr, Maghrib, Isha (3) + Days 1..6: 6 * 5 (30) = 33
      expect(result.scheduledCount, equals(33));
      expect(fakeClient.scheduledById.containsKey(5000), isFalse); // Day 0 Fajr
      expect(fakeClient.scheduledById.containsKey(5001), isFalse); // Day 0 Dhuhr
      expect(fakeClient.scheduledById.containsKey(5002), isTrue); // Day 0 Asr
    });

    test('repeated rescheduling is idempotent and creates zero duplicates', () async {
      final fakeClient = _FakePrayerNotificationClient();
      final calcService = _DeterministicCalculationService();
      final DateTime now = DateTime(2026, 3, 20, 4, 0);

      final service = PrayerNotificationService(
        client: fakeClient,
        calculationService: calcService,
        clock: () => now,
      );

      final settings = PrayerNotificationSettings(enabled: true);
      await service.reschedule(
        notificationSettings: settings,
        prayerSettings: const PrayerSettings.defaults(),
        latitude: 21.4225,
        longitude: 39.8262,
      );
      await service.reschedule(
        notificationSettings: settings,
        prayerSettings: const PrayerSettings.defaults(),
        latitude: 21.4225,
        longitude: 39.8262,
      );

      expect(fakeClient.scheduledById.length, equals(35));
      final pending = await fakeClient.pendingNotificationRequests();
      expect(pending.length, equals(40)); // 5 Adhkar + 35 Prayer
    });

    test(
      'disabled master switch or denied permission schedules nothing and never cancels Adhkar',
      () async {
        final fakeClient = _FakePrayerNotificationClient(
          permissionGranted: true,
        );
        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: _DeterministicCalculationService(),
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        // Schedule first
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(enabled: true),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(fakeClient.scheduledById.length, equals(35));

        // Master disabled -> cancels only prayer IDs, schedules 0
        final disabledResult = await service.reschedule(
          notificationSettings: PrayerNotificationSettings(enabled: false),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(disabledResult.scheduledCount, equals(0));
        expect(disabledResult.disabled, isTrue);
        expect(fakeClient.scheduledById, isEmpty);
        expect(fakeClient.nonPrayerPending.length, equals(5));

        // Denied permission -> schedules 0 and never calls requestPermission
        fakeClient.permissionGranted = false;
        final deniedResult = await service.reschedule(
          notificationSettings: PrayerNotificationSettings(enabled: true),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(deniedResult.scheduledCount, equals(0));
        expect(deniedResult.permissionGranted, isFalse);
        expect(fakeClient.requestPermissionCalls, equals(0));
        expect(fakeClient.scheduledById, isEmpty);
      },
    );

    test(
      'short and silent modes use distinct Android channels and matching iOS sound flags',
      () async {
        final fakeClient = _FakePrayerNotificationClient(
          exactAlarmsAllowed: false,
        );
        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: _DeterministicCalculationService(),
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        // Short sound
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            soundMode: PrayerNotificationSound.short,
          ),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );

        final shortRecord = fakeClient.scheduledById[5000]!;
        expect(
          shortRecord.details.android!.channelId,
          equals(PrayerNotificationService.shortSoundChannelId),
        );
        expect(shortRecord.details.android!.playSound, isTrue);
        expect(shortRecord.details.iOS!.presentSound, isTrue);
        expect(
          shortRecord.androidScheduleMode,
          equals(AndroidScheduleMode.inexactAllowWhileIdle),
        );

        // Silent mode
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            soundMode: PrayerNotificationSound.silent,
          ),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );

        final silentRecord = fakeClient.scheduledById[5000]!;
        expect(
          silentRecord.details.android!.channelId,
          equals(PrayerNotificationService.silentChannelId),
        );
        expect(silentRecord.details.android!.playSound, isFalse);
        expect(silentRecord.details.android!.silent, isTrue);
        expect(silentRecord.details.iOS!.presentSound, isFalse);
      },
    );

    test(
      'respects per-prayer toggles and recalculates for method, Madhab, coordinate, and date changes',
      () async {
        final fakeClient = _FakePrayerNotificationClient();
        final calcService = _DeterministicCalculationService();
        DateTime now = DateTime(2026, 3, 20, 4, 0);

        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: calcService,
          clock: () => now,
        );

        // Only Fajr and Asr enabled
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            fajr: true,
            dhuhr: false,
            asr: true,
            maghrib: false,
            isha: false,
          ),
          prayerSettings: PrayerSettings(
            calculationMode: PrayerCalculationMode.manual,
            manualCalculationMethod: CalculationMethod.muslim_world_league,
            madhab: Madhab.shafi,
          ),
          latitude: 21.4225,
          longitude: 39.8262,
        );

        expect(fakeClient.scheduledById.length, equals(14)); // 7 * 2
        expect(fakeClient.scheduledById[5000]!.body, contains('05:00')); // Fajr
        expect(fakeClient.scheduledById[5002]!.body, contains('03:30')); // Shafi Asr

        // Change calculation method (Umm al-Qura -> +10m Fajr) & Hanafi Asr (04:30)
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            fajr: true,
            dhuhr: false,
            asr: true,
            maghrib: false,
            isha: false,
          ),
          prayerSettings: PrayerSettings(
            calculationMode: PrayerCalculationMode.manual,
            manualCalculationMethod: CalculationMethod.umm_al_qura,
            madhab: Madhab.hanafi,
          ),
          latitude: 21.4225,
          longitude: 39.8262,
        );

        expect(fakeClient.scheduledById[5000]!.body, contains('05:10'));
        expect(fakeClient.scheduledById[5002]!.body, contains('04:30'));

        // Change coordinates (southern hemisphere adds 5m in our deterministic stub) & date
        now = DateTime(2026, 3, 21, 4, 0);
        await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            fajr: true,
            dhuhr: false,
            asr: false,
            maghrib: false,
            isha: false,
          ),
          prayerSettings: PrayerSettings(
            calculationMode: PrayerCalculationMode.manual,
            manualCalculationMethod: CalculationMethod.umm_al_qura,
            madhab: Madhab.hanafi,
          ),
          latitude: -33.8688,
          longitude: 151.2093,
        );

        expect(fakeClient.scheduledById[5000]!.body, contains('05:15'));
        expect(calcService.requestedDates.last, equals(DateTime(2026, 3, 27)));
      },
    );

    test(
      'reports exact skippedDueToLimitCount under iOS 64-notification ceiling while excluding disabled/past prayers and preserving other features',
      () async {
        final fakeClient = _FakePrayerNotificationClient();
        // 55 existing non-prayer pending notifications -> only 9 slots remain
        fakeClient.nonPrayerPending.clear();
        for (int i = 0; i < 55; i++) {
          fakeClient.nonPrayerPending.add(
            PendingNotificationRequest(1000 + i, 'Other', 'Body', null),
          );
        }

        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: _DeterministicCalculationService(),
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        // 35 eligible future prayers: 9 scheduled, 26 omitted due to limit
        final firstResult = await service.reschedule(
          notificationSettings: PrayerNotificationSettings(enabled: true),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );

        expect(firstResult.scheduledCount, equals(9));
        expect(firstResult.skippedDueToLimitCount, equals(26));
        final totalPending = await fakeClient.pendingNotificationRequests();
        expect(totalPending.length, equals(64));
        expect(fakeClient.nonPrayerPending.length, equals(55));

        // Repeated rescheduling yields consistent counts without losing non-prayer slots
        final secondResult = await service.reschedule(
          notificationSettings: PrayerNotificationSettings(enabled: true),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(secondResult.scheduledCount, equals(9));
        expect(secondResult.skippedDueToLimitCount, equals(26));
        expect(fakeClient.nonPrayerPending.length, equals(55));

        // Disabled prayers (Asr + Maghrib) must NOT count toward skippedDueToLimitCount:
        // 7 * 3 = 21 eligible -> 9 scheduled, 12 omitted due to limit.
        final subsetResult = await service.reschedule(
          notificationSettings: PrayerNotificationSettings(
            enabled: true,
            asr: false,
            maghrib: false,
          ),
          prayerSettings: const PrayerSettings.defaults(),
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(subsetResult.scheduledCount, equals(9));
        expect(subsetResult.skippedDueToLimitCount, equals(12));
      },
    );

    test(
      'syncPrayerNotificationsOnStartup uses cached coordinates without permission prompts and tolerates errors safely',
      () async {
        final fakeClient = _FakePrayerNotificationClient(
          permissionGranted: true,
        );
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();

        await notifSettingsService.updateEnabled(true);
        await notifSettingsService.saveLastCoordinates(
          latitude: 21.4225,
          longitude: 39.8262,
        );

        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: _DeterministicCalculationService(),
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
          clock: () => DateTime(2026, 3, 20, 4, 0),
        );

        await app_main.syncPrayerNotificationsOnStartup(service);

        expect(fakeClient.requestPermissionCalls, equals(0));
        expect(fakeClient.scheduledById.length, equals(35));
        expect(fakeClient.nonPrayerPending.length, equals(5));

        // Failure during startup sync never throws or blocks launch
        final throwingService = PrayerNotificationService(
          client: _ThrowingNotificationClient(),
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
        );
        await expectLater(
          app_main.syncPrayerNotificationsOnStartup(throwingService),
          completes,
        );
      },
    );

    test(
      'syncFromPersistedState detects date or timezone change on resume and reschedules without prompting',
      () async {
        final fakeClient = _FakePrayerNotificationClient(
          permissionGranted: true,
          timezoneName: 'UTC',
        );
        final prayerSettingsService = PrayerSettingsService();
        final notifSettingsService = PrayerNotificationSettingsService();
        DateTime now = DateTime(2026, 3, 20, 4, 0);

        await notifSettingsService.updateEnabled(true);
        await notifSettingsService.saveLastCoordinates(
          latitude: 21.4225,
          longitude: 39.8262,
        );
        await prayerSettingsService.updateMadhab(Madhab.shafi);

        final service = PrayerNotificationService(
          client: fakeClient,
          calculationService: _DeterministicCalculationService(),
          prayerSettingsService: prayerSettingsService,
          notificationSettingsService: notifSettingsService,
          clock: () => now,
        );

        final first = await service.syncFromPersistedState(
          onlyIfDateOrTimezoneChanged: true,
        );
        expect(first.scheduledCount, equals(35));

        // Same day & same timezone -> lightweight no-op
        final sameDay = await service.syncFromPersistedState(
          onlyIfDateOrTimezoneChanged: true,
        );
        expect(sameDay.scheduledCount, equals(0));
        expect(sameDay.cancelledCount, equals(0));

        // Timezone changes -> detects change and reschedules without prompting
        fakeClient.timezoneName = 'Asia/Riyadh';
        final tzChanged = await service.syncFromPersistedState(
          onlyIfDateOrTimezoneChanged: true,
        );
        expect(tzChanged.scheduledCount, equals(35));
        expect(fakeClient.requestPermissionCalls, equals(0));
      },
    );
  });
}

