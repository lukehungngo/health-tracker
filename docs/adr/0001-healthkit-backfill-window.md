# ADR 0001: Limit HealthKit backfill to 12 months

Status: Accepted (2026-10-02)

## Context

An unbounded anchored query uploaded years of Apple Health samples. This consumed cloud storage and made initial sync slow.

## Decision

Each HealthKit sync uses a rolling cutoff of 12 calendar months before the sync starts. Anchored queries select samples ending on or after that cutoff, and uploads apply the same boundary as a defensive filter. Existing cloud records are not deleted by this change. Stable HealthKit UUIDs and upserts retain retry idempotency.

## Verification

`MetricSyncTests.testHealthKitBackfillStopsAtTwelveCalendarMonths` covers the calendar boundary and inclusion rule. The full iOS Simulator test suite passed (24 tests) on 2026-10-02. A real-device HealthKit sync is still required to verify anchored-query behavior.
