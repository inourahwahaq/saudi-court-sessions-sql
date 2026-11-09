-- Saudi first-instance court sessions, January to September 2026
-- Engine: SQLite. Input table: raw_sessions (one row per session, loaded from the monthly CSV files).
-- Each "@export name" block is written to output/name.csv by run_analysis.py.

-- ============================================================
-- 1. Lookup tables
-- ============================================================
DROP TABLE IF EXISTS dim_region;
CREATE TABLE dim_region (region_ar TEXT PRIMARY KEY, region_en TEXT NOT NULL);
INSERT INTO dim_region VALUES
  ('منطقة الرياض','Riyadh'), ('منطقة مكة المكرمه','Makkah'), ('منطقة الشرقية','Eastern'),
  ('منطقة عسير','Asir'), ('منطقة المدينة المنوره','Madinah'), ('منطقة القصيم','Qassim'),
  ('منطقة جازان','Jazan'), ('منطقة تبوك','Tabuk'), ('منطقة حائل','Hail'), ('منطقة الجوف','Al Jawf'),
  ('منطقة نجران','Najran'), ('منطقة الحدود الشمالية','Northern Borders'), ('منطقة الباحة','Al Bahah'),
  ('الخدمات الرقمية','Digital Services');

DROP TABLE IF EXISTS dim_case_type;
CREATE TABLE dim_case_type (case_type_ar TEXT PRIMARY KEY, case_type_en TEXT NOT NULL);
INSERT INTO dim_case_type VALUES
  ('عامة','General'), ('جزائية','Criminal'), ('أحوال شخصية','Personal Status'), ('عمالية','Labour'),
  ('تجاري','Commercial'), ('تنفيذ','Enforcement'), ('إنهاءات','Non-contentious');

DROP TABLE IF EXISTS dim_city;
CREATE TABLE dim_city (city_ar TEXT PRIMARY KEY, city_en TEXT NOT NULL);
INSERT INTO dim_city VALUES
  ('الرياض','Riyadh'), ('جده','Jeddah'), ('الدمام','Dammam'), ('مكة المكرمة','Makkah'),
  ('المدينة المنورة','Madinah'), ('ابها','Abha'), ('الطائف','Taif'), ('بريده','Buraydah'),
  ('جيزان','Jazan'), ('تبوك','Tabuk'), ('الاحساء','Al Ahsa'), ('حائل','Hail'),
  ('حفر الباطن','Hafar Al Batin'), ('الخرج','Al Kharj'), ('نجران','Najran'), ('سكاكا','Sakaka'),
  ('الخبر','Khobar'), ('خميس مشيط','Khamis Mushait'), ('عرعر','Arar'), ('الباحه','Al Bahah');

-- ============================================================
-- 2. Clean table
-- ============================================================
DROP TABLE IF EXISTS sessions;
CREATE TABLE sessions AS
SELECT r.reference_no,
       date(replace(r.session_date, '/', '-'))                AS session_date,
       substr(replace(r.session_date, '/', '-'), 1, 7)        AS month,
       CAST(strftime('%w', replace(r.session_date, '/', '-')) AS INTEGER) AS weekday_no,
       g.region_en                                            AS region,
       COALESCE(c.city_en, r.city_ar)                         AS city,
       t.case_type_en                                         AS case_type,
       r.city_ar = 'عام'                                       AS is_digital
FROM raw_sessions r
JOIN dim_region g    ON g.region_ar = r.region_ar
JOIN dim_case_type t ON t.case_type_ar = r.case_type_ar
LEFT JOIN dim_city c ON c.city_ar = r.city_ar;

CREATE INDEX idx_sessions_month ON sessions (month);
CREATE INDEX idx_sessions_date  ON sessions (session_date);

-- ============================================================
-- 3. Data quality checks
-- ============================================================
-- @export data_quality
SELECT 'raw rows' AS check_name, COUNT(*) AS value FROM raw_sessions
UNION ALL SELECT 'clean rows', COUNT(*) FROM sessions
UNION ALL SELECT 'rows lost in joins', (SELECT COUNT(*) FROM raw_sessions) - (SELECT COUNT(*) FROM sessions)
UNION ALL SELECT 'invalid dates', COUNT(*) FROM sessions WHERE session_date IS NULL
UNION ALL SELECT 'reference numbers used twice', COUNT(*) FROM (SELECT reference_no FROM sessions GROUP BY 1 HAVING COUNT(*) > 1)
UNION ALL SELECT 'digital service sessions', SUM(is_digital) FROM sessions;

-- ============================================================
-- 4. Working days: a day counts when courts held at least 3,000 sessions
-- ============================================================
DROP TABLE IF EXISTS daily;
CREATE TABLE daily AS
SELECT session_date, month, weekday_no, COUNT(*) AS sessions, COUNT(*) >= 3000 AS is_working_day
FROM sessions GROUP BY session_date, month, weekday_no;

-- @export daily_profile
SELECT weekday_no, COUNT(*) AS days, SUM(is_working_day) AS working_days,
       MIN(sessions) AS min_sessions, MAX(sessions) AS max_sessions, ROUND(AVG(sessions)) AS avg_sessions
FROM daily GROUP BY weekday_no ORDER BY weekday_no;

-- ============================================================
-- 5. Monthly trend, adjusted for working days
-- ============================================================
-- @export monthly
WITH m AS (
  SELECT month, SUM(sessions) AS sessions, SUM(is_working_day) AS working_days FROM daily GROUP BY month
)
SELECT month, sessions, working_days,
       ROUND(1.0 * sessions / working_days) AS sessions_per_working_day,
       ROUND(100.0 * (sessions - LAG(sessions) OVER (ORDER BY month)) / LAG(sessions) OVER (ORDER BY month), 1) AS change_pct,
       ROUND(100.0 * ((1.0 * sessions / working_days) - LAG(1.0 * sessions / working_days) OVER (ORDER BY month))
             / LAG(1.0 * sessions / working_days) OVER (ORDER BY month), 1) AS per_day_change_pct
FROM m ORDER BY month;

-- ============================================================
-- 6. Case type by month: sessions per working day, indexed to each type's own average
-- ============================================================
-- @export heatmap
WITH wd AS (SELECT month, SUM(is_working_day) AS working_days FROM daily GROUP BY month),
base AS (
  SELECT s.case_type, s.month, COUNT(*) AS sessions, 1.0 * COUNT(*) / wd.working_days AS per_day
  FROM sessions s JOIN wd ON wd.month = s.month
  GROUP BY s.case_type, s.month
)
SELECT case_type, month, sessions, ROUND(per_day) AS per_working_day,
       ROUND(100 * per_day / AVG(per_day) OVER (PARTITION BY case_type)) AS index_to_type_average
FROM base ORDER BY case_type, month;

-- @export case_types
SELECT case_type, COUNT(*) AS sessions,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM sessions GROUP BY case_type ORDER BY sessions DESC;

-- ============================================================
-- 7. Cities: rank and running share, physical courts only
-- ============================================================
-- @export cities
WITH c AS (SELECT city, region, COUNT(*) AS sessions FROM sessions WHERE is_digital = 0 GROUP BY city, region)
SELECT RANK() OVER (ORDER BY sessions DESC) AS city_rank, city, region, sessions,
       ROUND(100.0 * sessions / SUM(sessions) OVER (), 1) AS share_pct,
       ROUND(100.0 * SUM(sessions) OVER (ORDER BY sessions DESC ROWS UNBOUNDED PRECEDING) / SUM(sessions) OVER (), 1) AS running_share_pct
FROM c ORDER BY city_rank;

-- ============================================================
-- 8. Case mix by region: where each type is over-represented
-- ============================================================
-- @export region_mix
WITH r AS (
  SELECT region, case_type, COUNT(*) AS sessions FROM sessions WHERE is_digital = 0 GROUP BY region, case_type
),
s AS (
  SELECT region, case_type, sessions,
         1.0 * sessions / SUM(sessions) OVER (PARTITION BY region) AS region_share,
         1.0 * SUM(sessions) OVER (PARTITION BY case_type) / SUM(sessions) OVER () AS national_share
  FROM r
)
SELECT region, case_type, sessions, ROUND(100 * region_share, 1) AS region_share_pct,
       ROUND(100 * national_share, 1) AS national_share_pct,
       ROUND(region_share / national_share, 2) AS concentration
FROM s ORDER BY region, case_type;

-- ============================================================
-- 9. Headline numbers
-- ============================================================
-- @export kpis
SELECT (SELECT COUNT(*) FROM sessions) AS total_sessions,
       (SELECT SUM(is_working_day) FROM daily) AS working_days,
       (SELECT ROUND(1.0 * SUM(sessions) / SUM(is_working_day)) FROM daily) AS sessions_per_working_day,
       (SELECT ROUND(100.0 * SUM(region = 'Riyadh') / COUNT(*), 1) FROM sessions) AS riyadh_region_share_pct,
       (SELECT COUNT(DISTINCT city) FROM sessions WHERE is_digital = 0) AS cities;

-- ============================================================
-- 10. One flat table for the Tableau dashboard
-- ============================================================
-- @export tableau_data
WITH wd AS (SELECT month, SUM(is_working_day) AS working_days FROM daily GROUP BY month),
names AS (
  SELECT wd.month, wd.working_days,
         CASE substr(wd.month, 6, 2) WHEN '01' THEN 'Jan' WHEN '02' THEN 'Feb' WHEN '03' THEN 'Mar' WHEN '04' THEN 'Apr' WHEN '05' THEN 'May'
              WHEN '06' THEN 'Jun' WHEN '07' THEN 'Jul' WHEN '08' THEN 'Aug' WHEN '09' THEN 'Sep' END AS month_label
  FROM wd
),
lowest AS (
  SELECT month FROM (SELECT month, 1.0 * SUM(sessions) / SUM(is_working_day) AS per_day FROM daily GROUP BY month) ORDER BY per_day LIMIT 1
),
per_type AS (
  SELECT s.case_type, s.month, COUNT(*) AS sessions, 1.0 * COUNT(*) / wd.working_days AS per_day
  FROM sessions s JOIN wd ON wd.month = s.month GROUP BY s.case_type, s.month
),
indexed AS (
  SELECT case_type, month, sessions, 100 * per_day / AVG(per_day) OVER (PARTITION BY case_type) AS idx FROM per_type
)
SELECT 'cube' AS rec, n.month_label, n.month_label || ', ' || n.working_days || ' days' AS month_days, s.case_type,
       s.city, CASE WHEN s.is_digital = 1 THEN 'Digital' ELSE 'Physical' END AS court_kind,
       COUNT(*) AS sessions, n.working_days, NULL AS idx, '' AS band,
       CASE WHEN s.month = (SELECT month FROM lowest) THEN 'Lowest' ELSE 'Normal' END AS highlight
FROM sessions s JOIN names n ON n.month = s.month
GROUP BY n.month_label, month_days, s.case_type, s.city, court_kind, n.working_days, highlight
UNION ALL
SELECT 'heat', n.month_label, n.month_label || ', ' || n.working_days || ' days', i.case_type, '', 'Physical', i.sessions, n.working_days, ROUND(i.idx),
       CASE WHEN ROUND(i.idx) <= 85 THEN 'Well below' WHEN ROUND(i.idx) <= 95 THEN 'Below' WHEN ROUND(i.idx) <= 105 THEN 'Near average' WHEN ROUND(i.idx) <= 110 THEN 'Above' ELSE 'Well above' END,
       ''
FROM indexed i JOIN names n ON n.month = i.month;
