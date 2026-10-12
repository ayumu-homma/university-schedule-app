import 'package:shared_domain/shared_domain.dart' as domain;

import '../data/local_notification_readonly_snapshot.dart';
import '../domain/local_notification_models.dart';
import '../domain/local_notification_planner.dart';

/// Shared planner result passed to the native guarded publication boundary.
/// The full plan is retained in the payload; the 200 reservation bound is a
/// native scheduling concern and never truncates this durable projection.
class LocalNotificationProjection {
  const LocalNotificationProjection({
    required this.planningNow,
    required this.windowEnd,
    required this.sourceEpoch,
    required this.expectedPreviousProjectionEpoch,
    required this.projectionEpoch,
    required this.capped,
    required this.distinctTriggerBuckets,
    required this.context,
    required this.plans,
  });

  static const protocolVersion = 1;
  static const horizonDays = 45;
  static const maxOsTriggerBuckets = 200;

  final DateTime planningNow;
  final DateTime windowEnd;
  final int sourceEpoch;
  final int expectedPreviousProjectionEpoch;
  final int projectionEpoch;
  final bool capped;
  final int distinctTriggerBuckets;
  final LocalNotificationContextTuple context;
  final List<LocalNotificationPlan> plans;

  Map<String, Object?> toPublicationPayload({
    required String regionId,
    required String ownerHash,
    required int generation,
    required String activationToken,
    String? databasePath,
    String? jobRunToken,
  }) =>
      {
        'schemaVersion': protocolVersion,
        'scope': {
          'regionId': regionId,
          'ownerHash': ownerHash,
          'activationToken': activationToken,
          'generation': generation,
        },
        if (databasePath != null) 'databasePath': databasePath,
        if (jobRunToken != null) 'runToken': jobRunToken,
        'ownerUserId': context.ownerUserId,
        'sourceEpoch': sourceEpoch,
        'expectedProjectionEpoch': expectedPreviousProjectionEpoch,
        'projectionEpoch': projectionEpoch,
        'planningNowMs': planningNow.toUtc().millisecondsSinceEpoch,
        'windowStartMs': planningNow.toUtc().millisecondsSinceEpoch,
        'windowEndMs': windowEnd.toUtc().millisecondsSinceEpoch,
        'context': context.toJson(),
        'capped': capped,
        'distinctTriggerBuckets': distinctTriggerBuckets,
        'plans': plans.map((plan) => plan.toJson()).toList(growable: false),
      };
}

class LocalNotificationProjectionComputer {
  const LocalNotificationProjectionComputer({
    this.planner = const LocalNotificationPlanner(),
  });

  final LocalNotificationPlanner planner;

  LocalNotificationProjection compute(
    LocalNotificationReadonlySnapshot snapshot, {
    required DateTime nowUtc,
  }) {
    final planningNow = nowUtc.toUtc();
    final projectionEpoch = snapshot.previousProjectionEpoch + 1;
    final plans = planner.plan(
      ownerUserId: snapshot.context.ownerUserId,
      projectionService: domain.CalendarProjectionService(),
      courses: snapshot.courses,
      periodSettings: snapshot.periodSettings,
      assignments: snapshot.assignments,
      assignmentStates: snapshot.assignmentStates,
      exams: snapshot.exams,
      events: snapshot.events,
      eventExceptions: snapshot.eventExceptions,
      settings: snapshot.settings,
      now: planningNow,
      sourceEpoch: snapshot.sourceEpoch,
      projectionEpoch: projectionEpoch,
      termStart: snapshot.termStart,
      termEnd: snapshot.termEnd,
      instructionStart: snapshot.instructionStart,
      instructionEnd: snapshot.instructionEnd,
      importedReminderRules: snapshot.importedReminderRules,
    );
    final windowEnd = planningNow.add(planner.horizon);
    final buckets = plans
        .where((plan) =>
            plan.eligible &&
            plan.triggerAt.isAfter(planningNow) &&
            plan.triggerAt.isBefore(windowEnd))
        .map((plan) => plan.triggerAt.toUtc().millisecondsSinceEpoch)
        .toSet();
    return LocalNotificationProjection(
      planningNow: planningNow,
      windowEnd: windowEnd,
      sourceEpoch: snapshot.sourceEpoch,
      expectedPreviousProjectionEpoch: snapshot.previousProjectionEpoch,
      projectionEpoch: projectionEpoch,
      capped: buckets.length > LocalNotificationProjection.maxOsTriggerBuckets,
      distinctTriggerBuckets: buckets.length,
      context: snapshot.context,
      plans: plans,
    );
  }
}
