-- Query inspeksi manual. File ini tidak dijalankan oleh pipeline produksi.

SELECT * FROM analytics.eda_failure_readiness_summary ORDER BY metric;
SELECT * FROM analytics.eda_failure_rate_by_year ORDER BY observation_year;
SELECT * FROM analytics.eda_target_class_distribution ORDER BY label_value;
SELECT * FROM analytics.eda_snapshot_master_coverage ORDER BY feature_name;
SELECT * FROM analytics.eda_snapshot_cadence_comparison ORDER BY cadence_days;
SELECT * FROM analytics.eda_failure_unit_comparison ORDER BY analysis_unit;
SELECT * FROM analytics.eda_incomplete_failure_summary
ORDER BY followup_review_group;
SELECT * FROM analytics.eda_outlier_summary ORDER BY check_name;
SELECT * FROM analytics.eda_journey_quality_summary ORDER BY check_order;
SELECT * FROM analytics.eda_fuzzy_mapping_review
ORDER BY mapping_type, event_count DESC;
SELECT * FROM analytics.eda_item_activity_summary
ORDER BY event_count DESC LIMIT 20;
SELECT * FROM analytics.eda_location_activity_summary
ORDER BY event_count DESC LIMIT 20;
SELECT * FROM analytics.eda_location_lifecycle_summary
ORDER BY matched_lifecycle_count DESC LIMIT 20;
SELECT * FROM analytics.eda_daily_activity_anomaly
WHERE is_extreme_activity_day ORDER BY event_count DESC;

SELECT cycle_quality_status, COUNT(*) AS cycle_count
FROM analytics.item_installation_cycle
GROUP BY cycle_quality_status
ORDER BY cycle_count DESC;

SELECT target_quality_status, COUNT(*) AS snapshot_count
FROM analytics.item_observation_30d
GROUP BY target_quality_status
ORDER BY snapshot_count DESC;
