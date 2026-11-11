import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/prayer_notification_settings.dart';
import '../models/prayer_settings.dart';
import 'prayer_calculation_service.dart';
import 'prayer_notification_settings_service.dart';
import 'prayer_settings_service.dart';

/// Structured outcome returned by [PrayerNotificationService.reschedule].
@immutable
class PrayerNotificationSyncResult {
  /// Number of individual future prayer notifications scheduled (`0..35`).
  final int scheduledCount;

  /// Number of prayer notification IDs cancelled during the idempotent reset.
  final int cancelledCount;

  /// Number of eligible future obligatory prayer notifications omitted
  /// specifically because available capacity under iOS's 64-notification
  /// limit was exhausted.
  final int skippedDueToLimitCount;

  /// Whether OS notification permission was granted (read-only check).
  final bool permissionGranted;

  /// Whether scheduling was skipped because cached/active coordinates were
  /// missing.
  final bool missingCoordinates;

  /// Whether scheduling was skipped because master notifications were disabled.
  final bool disabled;

  const PrayerNotificationSyncResult({
    required this.scheduledCount,
    required this.cancelledCount,
    this.skippedDueToLimitCount = 0,
    required this.permissionGranted,
    this.missingCoordinates = false,
    this.disabled = false,
  });
}

/// Injectable platform abstraction over `flutter_local_notifications` and
/// `flutter_timezone` for [PrayerNotificationService].
///
/// Intentionally does **not** expose `cancelAll()` so prayer scheduling can
/// never accidentally cancel notifications owned by other features (such as
/// Adhkar reminders).
abstract class PrayerNotificationClient {
  /// Read-only check for OS notification permission (never prompts the user).
  Future<bool> isPermissionGranted();

  /// Explicitly requests OS notification permission following a user action.
  Future<bool> requestPermission();

  /// Read-only check for whether Android exact alarms are available (never
  /// opens system settings screens).
  Future<bool> canScheduleExactNotifications();

  /// Opens the OS application settings screen (explicit user action only).
  Future<bool> openAppSettings();

  /// Returns the current device IANA timezone identifier.
  Future<String> getLocalTimezone();

  /// Creates the Android notification channels owned by the prayer feature.
  Future<void> createAndroidChannels(List<AndroidNotificationChannel> channels);

  /// Lists currently pending scheduled notifications on the device.
  Future<List<PendingNotificationRequest>> pendingNotificationRequests();

  /// Cancels a single notification by its [id].
  Future<void> cancel(int id);

  /// Schedules a single future local notification at [scheduledDate].
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
  });
}

/// Production [PrayerNotificationClient] delegating to the shared
/// [FlutterLocalNotificationsPlugin] singleton initialized at app startup.
class DefaultPrayerNotificationClient implements PrayerNotificationClient {
  final FlutterLocalNotificationsPlugin _plugin;

  DefaultPrayerNotificationClient({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  @override
  Future<bool> isPermissionGranted() async {
    try {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? granted = await androidImpl.areNotificationsEnabled();
        return granted ?? false;
      }

      final iosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosImpl != null) {
        final NotificationsEnabledOptions? options =
            await iosImpl.checkPermissions();
        return (options?.isEnabled ?? false) ||
            (options?.isAlertEnabled ?? false) ||
            (options?.isProvisionalEnabled ?? false);
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? granted =
            await androidImpl.requestNotificationsPermission();
        return granted ?? false;
      }

      final iosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosImpl != null) {
        final bool? granted = await iosImpl.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<bool> canScheduleExactNotifications() async {
    try {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        final bool? canExact = await androidImpl.canScheduleExactNotifications();
        return canExact ?? false;
      }
    } catch (_) {}
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await Geolocator.openAppSettings();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> getLocalTimezone() => FlutterTimezone.getLocalTimezone();

  @override
  Future<void> createAndroidChannels(
    List<AndroidNotificationChannel> channels,
  ) async {
    try {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        for (final channel in channels) {
          await androidImpl.createNotificationChannel(channel);
        }
      }
    } catch (_) {}
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() {
    return _plugin.pendingNotificationRequests();
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
  }) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduledDate,
      notificationDetails,
      androidScheduleMode: androidScheduleMode,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}

/// Isolated local notification scheduler for the five daily obligatory prayers
/// (`Fajr`, `Dhuhr`, `Asr`, `Maghrib`, `Isha`).
///
/// ### Architectural Guarantees
/// - **Disjoint ID space:** Exclusively uses IDs `5000..5069` (`5000 + dayOffset * 10 + prayerIndex`),
///   never colliding with existing Adhkar IDs (`1001`, `1002`, `2001..2003`, `9999`).
/// - **No global cancellation:** Never calls `cancelAll()`; cancels only IDs
///   within `5000..5069`.
/// - **Sunrise exclusion:** `Prayer.sunrise` is never eligible and never scheduled.
/// - **Rolling 7-day horizon:** Schedules at most `35` notifications so total
///   device pending notifications stay well within iOS's 64-notification limit
///   (accounting for existing repeating Adhkar notifications).
/// - **Timezone limitation:** Uses [PrayerCalculationService] with `utcOffset == null`
///   and refreshes `tz.local` from the device OS timezone. Accurate scheduling
///   assumes the device's OS timezone matches the location's timezone.
class PrayerNotificationService {
  /// Minimum reserved notification ID for prayer notifications.
  static const int minNotificationId = 5000;

  /// Maximum reserved notification ID for prayer notifications.
  static const int maxNotificationId = 5069;

  /// Rolling horizon in calendar days.
  static const int rollingHorizonDays = 7;

  /// Maximum prayer notifications across [rollingHorizonDays] days (7 × 5 = 35).
  static const int maxPrayerNotifications = 35;

  /// iOS system limit for total pending local notifications per application.
  static const int iosPendingNotificationLimit = 64;

  /// Android channel ID for short system notification sound.
  static const String shortSoundChannelId = 'prayer_times_short_sound_channel';
  static const String shortSoundChannelName = 'تنبيهات مواقيت الصلاة';
  static const String shortSoundChannelDescription =
      'إشعارات مواقيت الصلوات الخمس بصوت إشعار قصير';

  /// Android channel ID for silent prayer notifications.
  static const String silentChannelId = 'prayer_times_silent_channel';
  static const String silentChannelName = 'تنبيهات مواقيت الصلاة (صامت)';
  static const String silentChannelDescription =
      'إشعارات مواقيت الصلوات الخمس بدون صوت';

  final PrayerNotificationClient _client;
  final PrayerCalculationService _calculationService;
  final PrayerSettingsService _prayerSettingsService;
  final PrayerNotificationSettingsService _notificationSettingsService;
  final DateTime Function() _clock;

  bool _timezonesInitialized = false;
  bool _channelsCreated = false;
  DateTime? _lastSyncDate;
  String? _lastSyncTimezone;

  PrayerNotificationService({
    PrayerNotificationClient? client,
    PrayerCalculationService? calculationService,
    PrayerSettingsService? prayerSettingsService,
    PrayerNotificationSettingsService? notificationSettingsService,
    DateTime Function()? clock,
  })  : _client = client ?? DefaultPrayerNotificationClient(),
        _calculationService =
            calculationService ?? const PrayerCalculationService(),
        _prayerSettingsService =
            prayerSettingsService ?? PrayerSettingsService(),
        _notificationSettingsService =
            notificationSettingsService ?? PrayerNotificationSettingsService(),
        _clock = clock ?? DateTime.now;

  /// Computes the deterministic notification ID (`5000..5069`) for a given
  /// [dayOffset] (`0..6`) and obligatory [prayer].
  ///
  /// Throws an [ArgumentError] if [dayOffset] is outside `0..6` or if [prayer]
  /// is not one of the five obligatory prayers (for example, [Prayer.sunrise]).
  static int notificationIdFor({
    required int dayOffset,
    required Prayer prayer,
  }) {
    if (dayOffset < 0 || dayOffset >= rollingHorizonDays) {
      throw RangeError.range(dayOffset, 0, rollingHorizonDays - 1, 'dayOffset');
    }
    final int? prayerIndex = PrayerNotificationSettings.prayerIndexFor(prayer);
    if (prayerIndex == null) {
      throw ArgumentError.value(
        prayer,
        'prayer',
        'Only obligatory prayers (Fajr, Dhuhr, Asr, Maghrib, Isha) can have a notification ID.',
      );
    }
    return minNotificationId + (dayOffset * 10) + prayerIndex;
  }

  /// All 35 deterministic notification IDs across the 7-day rolling horizon.
  static List<int> get allReservedSlotIds {
    final ids = <int>[];
    for (int dayOffset = 0; dayOffset < rollingHorizonDays; dayOffset++) {
      for (final prayer in PrayerNotificationSettings.eligiblePrayers) {
        ids.add(notificationIdFor(dayOffset: dayOffset, prayer: prayer));
      }
    }
    return List<int>.unmodifiable(ids);
  }

  /// Returns `true` if OS notification permission is currently granted without
  /// triggering a permission prompt.
  Future<bool> isPermissionGranted() => _client.isPermissionGranted();

  /// Requests OS notification permission explicitly in response to a user
  /// action.
  Future<bool> requestPermission() => _client.requestPermission();

  /// Opens OS application settings manually following an explicit user action.
  Future<bool> openAppSettings() => _client.openAppSettings();

  /// Ensures the two dedicated prayer Android channels exist.
  Future<void> ensureChannelsCreated() async {
    if (_channelsCreated) return;
    await _client.createAndroidChannels(<AndroidNotificationChannel>[
      const AndroidNotificationChannel(
        shortSoundChannelId,
        shortSoundChannelName,
        description: shortSoundChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
      const AndroidNotificationChannel(
        silentChannelId,
        silentChannelName,
        description: silentChannelDescription,
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    ]);
    _channelsCreated = true;
  }

  /// Cancels **only** notification IDs inside the reserved prayer range
  /// (`5000..5069`). Never calls `cancelAll()` and never cancels Adhkar IDs.
  Future<int> cancelAllPrayerNotifications() async {
    final idsToCancel = <int>{...allReservedSlotIds};
    try {
      final pending = await _client.pendingNotificationRequests();
      for (final request in pending) {
        if (request.id >= minNotificationId &&
            request.id <= maxNotificationId) {
          idsToCancel.add(request.id);
        }
      }
    } catch (_) {}

    int cancelledCount = 0;
    for (final id in idsToCancel) {
      try {
        await _client.cancel(id);
        cancelledCount++;
      } catch (_) {}
    }
    return cancelledCount;
  }

  Future<String> _refreshLocalTimezone() async {
    if (!_timezonesInitialized) {
      try {
        tz_data.initializeTimeZones();
      } catch (_) {}
      _timezonesInitialized = true;
    }

    String timezoneName = 'UTC';
    try {
      timezoneName = await _client.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezoneName));
      return timezoneName;
    } catch (_) {
      try {
        tz.setLocalLocation(tz.getLocation('UTC'));
      } catch (_) {}
      return timezoneName;
    }
  }

  /// Idempotently cancels old prayer notifications (`5000..5069`) and
  /// schedules the next 7 calendar days for all enabled obligatory prayers.
  ///
  /// Uses only read-only OS permission and exact-alarm checks; never prompts
  /// the user or opens OS settings.
  Future<PrayerNotificationSyncResult> reschedule({
    required PrayerNotificationSettings notificationSettings,
    required PrayerSettings prayerSettings,
    double? latitude,
    double? longitude,
  }) async {
    // Always cancel previously scheduled prayer IDs first so repeated calls
    // remain strictly idempotent without duplicate pending notifications.
    final int cancelledCount = await cancelAllPrayerNotifications();

    if (!notificationSettings.enabled ||
        !notificationSettings.hasAnyPrayerEnabled) {
      return PrayerNotificationSyncResult(
        scheduledCount: 0,
        cancelledCount: cancelledCount,
        permissionGranted: await _client.isPermissionGranted(),
        disabled: true,
      );
    }

    final bool permissionGranted = await _client.isPermissionGranted();
    if (!permissionGranted) {
      return PrayerNotificationSyncResult(
        scheduledCount: 0,
        cancelledCount: cancelledCount,
        permissionGranted: false,
      );
    }

    double? effectiveLat = latitude;
    double? effectiveLng = longitude;
    if (effectiveLat == null || effectiveLng == null) {
      final cached = await _notificationSettingsService.loadLastCoordinates();
      if (cached != null) {
        effectiveLat = cached.latitude;
        effectiveLng = cached.longitude;
      }
    }

    if (effectiveLat == null ||
        effectiveLng == null ||
        !PrayerCalculationService.areValidCoordinates(
          effectiveLat,
          effectiveLng,
        )) {
      return PrayerNotificationSyncResult(
        scheduledCount: 0,
        cancelledCount: cancelledCount,
        permissionGranted: true,
        missingCoordinates: true,
      );
    }

    final String activeTimezone = await _refreshLocalTimezone();
    await ensureChannelsCreated();

    final bool canExact = await _client.canScheduleExactNotifications();
    final AndroidScheduleMode scheduleMode = canExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    // Respect iOS's 64-pending-notification limit by checking how many
    // non-prayer pending notifications (e.g. Adhkar's 5 slots) are currently
    // queued.
    int nonPrayerPendingCount = 0;
    try {
      final pending = await _client.pendingNotificationRequests();
      nonPrayerPendingCount = pending
          .where(
            (req) => req.id < minNotificationId || req.id > maxNotificationId,
          )
          .length;
    } catch (_) {}

    final int availableSlots =
        (iosPendingNotificationLimit - nonPrayerPendingCount).clamp(
          0,
          maxPrayerNotifications,
        );

    final DateTime now = _clock();
    final tz.TZDateTime tzNow = tz.TZDateTime.from(now, tz.local);
    final NotificationDetails notificationDetails = _buildNotificationDetails(
      notificationSettings.soundMode,
    );

    int scheduledCount = 0;
    int skippedDueToLimitCount = 0;
    for (int dayOffset = 0; dayOffset < rollingHorizonDays; dayOffset++) {
      final DateTime targetDate = DateTime(
        now.year,
        now.month,
        now.day + dayOffset,
      );

      final result = _calculationService.tryCalculate(
        latitude: effectiveLat,
        longitude: effectiveLng,
        date: targetDate,
        settings: prayerSettings,
      );
      if (result == null) {
        continue;
      }

      for (final prayer in PrayerNotificationSettings.eligiblePrayers) {
        if (!notificationSettings.isPrayerEnabled(prayer)) {
          continue;
        }

        final DateTime? prayerTime = result.timeForPrayer(prayer);
        if (prayerTime == null || !prayerTime.isAfter(now)) {
          continue;
        }

        final tz.TZDateTime tzScheduled = tz.TZDateTime.from(
          prayerTime,
          tz.local,
        );
        if (!tzScheduled.isAfter(tzNow)) {
          continue;
        }

        if (scheduledCount >= availableSlots) {
          skippedDueToLimitCount++;
          continue;
        }

        final int id = notificationIdFor(dayOffset: dayOffset, prayer: prayer);
        final String prayerAr = prayerNameAr(prayer);
        final String title = 'موعد صلاة $prayerAr';
        final String body =
            'حان الآن وقت صلاة $prayerAr (${_formatTime12Hour(prayerTime)})';

        await _client.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: tzScheduled,
          notificationDetails: notificationDetails,
          androidScheduleMode: scheduleMode,
        );
        scheduledCount++;
      }
    }

    _lastSyncDate = DateTime(now.year, now.month, now.day);
    _lastSyncTimezone = activeTimezone;

    return PrayerNotificationSyncResult(
      scheduledCount: scheduledCount,
      cancelledCount: cancelledCount,
      skippedDueToLimitCount: skippedDueToLimitCount,
      permissionGranted: true,
    );
  }

  /// Loads persisted settings and cached coordinates (or optional override
  /// coordinates) and reschedules prayer notifications safely without prompting.
  Future<PrayerNotificationSyncResult> syncFromPersistedState({
    double? latitude,
    double? longitude,
    bool onlyIfDateOrTimezoneChanged = false,
  }) async {
    final notificationSettings =
        await _notificationSettingsService.loadSettings();
    final prayerSettings = await _prayerSettingsService.loadSettings();

    if (onlyIfDateOrTimezoneChanged && notificationSettings.enabled) {
      final now = _clock();
      final today = DateTime(now.year, now.month, now.day);
      final currentTimezone = await _refreshLocalTimezone();
      if (_lastSyncDate == today && _lastSyncTimezone == currentTimezone) {
        final bool granted = await _client.isPermissionGranted();
        if (granted) {
          return const PrayerNotificationSyncResult(
            scheduledCount: 0,
            cancelledCount: 0,
            permissionGranted: true,
          );
        }
      }
    }

    return reschedule(
      notificationSettings: notificationSettings,
      prayerSettings: prayerSettings,
      latitude: latitude,
      longitude: longitude,
    );
  }

  /// Records fresh coordinates when prayer notifications are enabled and
  /// immediately reschedules the 7-day rolling notification window.
  ///
  /// Does **not** persist coordinates when prayer notifications are disabled.
  Future<PrayerNotificationSyncResult> onCoordinatesUpdated({
    required double latitude,
    required double longitude,
    PrayerSettings? prayerSettings,
  }) async {
    final notificationSettings =
        await _notificationSettingsService.loadSettings();
    if (!notificationSettings.enabled) {
      return PrayerNotificationSyncResult(
        scheduledCount: 0,
        cancelledCount: 0,
        permissionGranted: await _client.isPermissionGranted(),
        disabled: true,
      );
    }

    await _notificationSettingsService.saveLastCoordinates(
      latitude: latitude,
      longitude: longitude,
    );

    final effectivePrayerSettings =
        prayerSettings ?? await _prayerSettingsService.loadSettings();

    return reschedule(
      notificationSettings: notificationSettings,
      prayerSettings: effectivePrayerSettings,
      latitude: latitude,
      longitude: longitude,
    );
  }

  static NotificationDetails _buildNotificationDetails(
    PrayerNotificationSound soundMode,
  ) {
    final bool useShortSound = soundMode == PrayerNotificationSound.short;

    final AndroidNotificationDetails androidDetails = useShortSound
        ? const AndroidNotificationDetails(
            shortSoundChannelId,
            shortSoundChannelName,
            channelDescription: shortSoundChannelDescription,
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            silent: false,
            styleInformation: BigTextStyleInformation(''),
          )
        : const AndroidNotificationDetails(
            silentChannelId,
            silentChannelName,
            channelDescription: silentChannelDescription,
            importance: Importance.high,
            priority: Priority.defaultPriority,
            playSound: false,
            enableVibration: false,
            silent: true,
            styleInformation: BigTextStyleInformation(''),
          );

    final DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentBadge: false,
      presentSound: useShortSound,
    );

    return NotificationDetails(android: androidDetails, iOS: iosDetails);
  }

  static String prayerNameAr(Prayer prayer) {
    switch (prayer) {
      case Prayer.fajr:
        return 'الفجر';
      case Prayer.dhuhr:
        return 'الظهر';
      case Prayer.asr:
        return 'العصر';
      case Prayer.maghrib:
        return 'المغرب';
      case Prayer.isha:
        return 'العشاء';
      case Prayer.sunrise:
      case Prayer.none:
        return '';
    }
  }

  static String _formatTime12Hour(DateTime dateTime) {
    final int hour24 = dateTime.hour;
    final int minute = dateTime.minute;
    final String period = hour24 >= 12 ? 'م' : 'ص';
    final int hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final String hh = hour12.toString().padLeft(2, '0');
    final String mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm $period';
  }
}

