import 'package:adhkar/features/prayer/data/models/prayer_notification_settings.dart';
import 'package:adhkar/features/prayer/data/services/prayer_notification_settings_service.dart';
import 'package:adhan/adhan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingWriteSharedPreferences implements SharedPreferences {
  @override
  Object? get(String key) => null;

  @override
  Future<bool> setString(String key, String value) async => false;

  @override
  Future<bool> remove(String key) async => false;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingSharedPreferences implements SharedPreferences {
  @override
  Future<bool> setString(String key, String value) async {
    throw StateError('Simulated disk write failure');
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('PrayerNotificationSettings Model Tests', () {
    test(
      'defaults have master switch disabled, short sound, all five prayers enabled, and no Sunrise',
      () {
        const defaults = PrayerNotificationSettings.defaults();

        expect(defaults.enabled, isFalse);
        expect(defaults.fajr, isTrue);
        expect(defaults.dhuhr, isTrue);
        expect(defaults.asr, isTrue);
        expect(defaults.maghrib, isTrue);
        expect(defaults.isha, isTrue);
        expect(defaults.soundMode, equals(PrayerNotificationSound.short));
        expect(defaults.schemaVersion, equals(1));

        // Five obligatory prayers only — Sunrise must never exist
        expect(
          PrayerNotificationSettings.eligiblePrayers,
          equals(const <Prayer>[
            Prayer.fajr,
            Prayer.dhuhr,
            Prayer.asr,
            Prayer.maghrib,
            Prayer.isha,
          ]),
        );
        expect(
          PrayerNotificationSettings.eligiblePrayers,
          isNot(contains(Prayer.sunrise)),
        );
        expect(PrayerNotificationSettings.prayerIndexFor(Prayer.sunrise), isNull);
        expect(defaults.isPrayerEnabled(Prayer.sunrise), isFalse);
        expect(defaults.toMap().containsKey('sunrise'), isFalse);
      },
    );

    test('serialization and deserialization round-trip preserves all fields', () {
      final custom = PrayerNotificationSettings(
        enabled: true,
        fajr: true,
        dhuhr: false,
        asr: true,
        maghrib: false,
        isha: true,
        soundMode: PrayerNotificationSound.silent,
      );

      final json = custom.toJsonString();
      final decoded = PrayerNotificationSettings.fromJsonString(json);

      expect(decoded, equals(custom));
    });

    test(
      'malformed JSON, invalid field types, and unsupported schemaVersion fall back safely',
      () {
        expect(
          PrayerNotificationSettings.fromJsonString('not-valid-json{{{'),
          equals(const PrayerNotificationSettings.defaults()),
        );
        expect(
          PrayerNotificationSettings.fromJsonString('[]'),
          equals(const PrayerNotificationSettings.defaults()),
        );
        expect(
          PrayerNotificationSettings.fromMap(<String, dynamic>{
            'schemaVersion': 99,
            'enabled': true,
            'soundMode': 'silent',
          }),
          equals(const PrayerNotificationSettings.defaults()),
        );
        expect(
          PrayerNotificationSettings.fromMap(<String, dynamic>{
            'schemaVersion': -1,
            'enabled': true,
          }),
          equals(const PrayerNotificationSettings.defaults()),
        );

        // Invalid per-field values safely fall back to defaults
        final sanitized = PrayerNotificationSettings.fromMap(<String, dynamic>{
          'schemaVersion': 1,
          'enabled': 'yes', // non-bool -> default false
          'fajr': 123, // non-bool -> default true
          'dhuhr': false,
          'soundMode': 'full_adhan', // invalid -> default short
        });
        expect(sanitized.enabled, isFalse);
        expect(sanitized.fajr, isTrue);
        expect(sanitized.dhuhr, isFalse);
        expect(sanitized.soundMode, equals(PrayerNotificationSound.short));
      },
    );
  });

  group('PrayerNotificationSettingsService Persistence & Cache Tests', () {
    test(
      'persists settings under dedicated key prayer_notification_settings_v1_json independently',
      () async {
        final service = PrayerNotificationSettingsService();
        await service.loadSettings();
        expect(service.currentSettings.enabled, isFalse);

        await service.updateEnabled(true);
        await service.updatePrayerEnabled(Prayer.asr, false);
        await service.updateSoundMode(PrayerNotificationSound.silent);

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.containsKey(PrayerNotificationSettingsService.storageKey),
          isTrue,
        );
        expect(
          PrayerNotificationSettingsService.storageKey,
          equals('prayer_notification_settings_v1_json'),
        );

        final reloaded = PrayerNotificationSettingsService();
        final loaded = await reloaded.loadSettings();
        expect(loaded.enabled, isTrue);
        expect(loaded.asr, isFalse);
        expect(loaded.fajr, isTrue);
        expect(loaded.soundMode, equals(PrayerNotificationSound.silent));

        // Attempting to toggle Sunrise does not alter settings
        final afterSunriseAttempt = await service.updatePrayerEnabled(
          Prayer.sunrise,
          true,
        );
        expect(afterSunriseAttempt, equals(loaded));
      },
    );

    test(
      'failed persistence (false return or exception) throws and leaves in-memory state unchanged',
      () async {
        final custom = PrayerNotificationSettings(
          enabled: true,
          fajr: false,
          soundMode: PrayerNotificationSound.silent,
        );
        expect(
          custom,
          isNot(equals(const PrayerNotificationSettings.defaults())),
        );

        final falseWriteService = PrayerNotificationSettingsService(
          preferencesProvider: () async => _FailingWriteSharedPreferences(),
        );
        await falseWriteService.loadSettings();
        expect(
          falseWriteService.currentSettings,
          equals(const PrayerNotificationSettings.defaults()),
        );

        // Attempting to persist genuinely different custom settings must throw
        // and leave in-memory settings strictly unchanged at defaults.
        await expectLater(
          falseWriteService.saveSettings(custom),
          throwsA(isA<PrayerNotificationSettingsStorageException>()),
        );
        expect(
          falseWriteService.currentSettings,
          equals(const PrayerNotificationSettings.defaults()),
        );
        expect(falseWriteService.currentSettings.enabled, isFalse);

        await expectLater(
          falseWriteService.updateEnabled(true),
          throwsA(isA<PrayerNotificationSettingsStorageException>()),
        );
        expect(falseWriteService.currentSettings.enabled, isFalse);

        await expectLater(
          falseWriteService.updateSoundMode(PrayerNotificationSound.silent),
          throwsA(isA<PrayerNotificationSettingsStorageException>()),
        );
        expect(
          falseWriteService.currentSettings.soundMode,
          equals(PrayerNotificationSound.short),
        );

        final throwingService = PrayerNotificationSettingsService(
          preferencesProvider: () async => _ThrowingSharedPreferences(),
        );
        await expectLater(
          throwingService.saveSettings(custom),
          throwsA(isA<PrayerNotificationSettingsStorageException>()),
        );
        expect(
          throwingService.currentSettings,
          equals(const PrayerNotificationSettings.defaults()),
        );
      },
    );

    test(
      'coordinate cache stores lat/lng only when notifications are enabled and clears when disabled',
      () async {
        final service = PrayerNotificationSettingsService();
        await service.loadSettings();

        // Disabled by default: must NOT store coordinates
        final storedWhileDisabled = await service.saveLastCoordinates(
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(storedWhileDisabled, isFalse);
        expect(await service.loadLastCoordinates(), isNull);

        // Enable notifications -> now coordinates can be stored
        await service.updateEnabled(true);
        final storedWhileEnabled = await service.saveLastCoordinates(
          latitude: 21.4225,
          longitude: 39.8262,
        );
        expect(storedWhileEnabled, isTrue);

        final prefs = await SharedPreferences.getInstance();
        final rawCache = prefs.getString(
          PrayerNotificationSettingsService.coordinatesCacheKey,
        );
        expect(rawCache, isNotNull);
        expect(rawCache, equals('{"latitude":21.4225,"longitude":39.8262}'));

        final loadedCoords = await service.loadLastCoordinates();
        expect(loadedCoords, isNotNull);
        expect(loadedCoords!.latitude, equals(21.4225));
        expect(loadedCoords.longitude, equals(39.8262));

        // Disabling notifications clears coordinate cache
        await service.updateEnabled(false);
        expect(await service.loadLastCoordinates(), isNull);
      },
    );
  });
}

