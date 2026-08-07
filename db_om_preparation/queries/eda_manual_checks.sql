-- Query inspeksi manual. File ini tidak dijalankan oleh pipeline produksi.

SELECT * FROM analytics.eda_failure_readiness_summary ORDER BY metric;
SELECT * FROM analytics.eda_failure_rate_by_year ORDER BY observation_year;
SELECT * FROM analytics.eda_target_class_distribution ORDER BY label_value;
SELECT * FROM analytics.eda_snapshot_master_coverage ORDER BY feature_name;
SELECT * FROM analytics.eda_snapshot_cadence_comparison ORDER BY cadence_days;
SELECT * FROM analytics.eda_failure_unit_comparison ORDER BY analysis_unit;
SELECT * FROM analytics.eda_part_terminal_structure_summary ORDER BY metric;
SELECT * FROM analytics.eda_bivariate_association_summary ORDER BY association;
SELECT * FROM analytics.eda_bivariate_terminal_type_target
ORDER BY positive_percentage DESC;
SELECT * FROM analytics.eda_bivariate_terminal_model_target
WHERE meets_minimum_support
ORDER BY positive_percentage DESC;
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

-- Keputusan final fitur dan output feature engineering.
SELECT *
FROM analytics.failure_30d_feature_catalog
ORDER BY decision, feature_group, feature_name;

SELECT *
FROM analytics.failure_30d_feature_quality_summary
ORDER BY metric;

SELECT temporal_split,
       COUNT(*) AS snapshot_count,
       COUNT(*) FILTER (WHERE target_failure_30d) AS positive_count
FROM analytics.failure_30d_model_labels
GROUP BY temporal_split
ORDER BY temporal_split;

SELECT *
FROM analytics.failure_30d_baseline_features
ORDER BY observation_on, installation_cycle_id
LIMIT 20;
