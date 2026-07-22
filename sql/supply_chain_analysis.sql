/* ============================================================
   SUPPLY CHAIN & INVENTORY OPTIMIZATION SQL PROJECT
   Author : Poornima Singh
   Stack  : PostgreSQL
   Data   : Kaggle Supply Chain Dataset (100 SKUs), normalized into
            categories / suppliers / warehouses / products, plus a
            synthetically generated 52-week purchase_orders and
            sales_orders history.
   ============================================================
   SECTIONS
    0. Schema (DDL)
    1. Data validation
    2. Descriptive inventory metrics
    3. ABC classification (with NTILE quartile cross-check)
    4. Reorder point & safety stock
    5. Stockout analysis
    6. Supplier lead-time reliability
    7. Category & warehouse rollups
    8. Monthly trend analysis
    9. Quality correlation analysis
   10. Synthesis: prioritized risk queries
   ============================================================ */


/* ============================================================
   0. SCHEMA (DDL)
   ============================================================ */

DROP TABLE IF EXISTS sales_orders;
DROP TABLE IF EXISTS purchase_orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS warehouses;
DROP TABLE IF EXISTS suppliers;
DROP TABLE IF EXISTS categories;

CREATE TABLE categories (
    category_id     SERIAL PRIMARY KEY,
    category_name   VARCHAR(50) NOT NULL
);

CREATE TABLE suppliers (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_name   VARCHAR(50) NOT NULL,
    hq_location     VARCHAR(50)
);

CREATE TABLE warehouses (
    warehouse_id    SERIAL PRIMARY KEY,
    warehouse_name  VARCHAR(80),
    city            VARCHAR(50)
);

CREATE TABLE products (
    sku                     VARCHAR(10) PRIMARY KEY,
    category_id             INTEGER REFERENCES categories(category_id),
    price                   NUMERIC(10,2),
    availability            INTEGER,
    annual_units_sold       INTEGER,
    revenue_generated       NUMERIC(12,2),
    customer_demographics   VARCHAR(50),
    starting_stock          INTEGER,
    order_lead_time         INTEGER,
    std_order_qty           INTEGER,
    shipping_times          INTEGER,
    shipping_carriers       VARCHAR(50),
    shipping_costs          NUMERIC(10,2),
    supplier_id             INTEGER REFERENCES suppliers(supplier_id),
    warehouse_id            INTEGER REFERENCES warehouses(warehouse_id),
    promised_lead_time      INTEGER,
    production_volumes      INTEGER,
    manufacturing_lead_time INTEGER,
    manufacturing_costs     NUMERIC(10,2),
    inspection_results      VARCHAR(20),
    defect_rate_pct         NUMERIC(6,3),
    transportation_modes    VARCHAR(20),
    routes                  VARCHAR(20),
    costs                   NUMERIC(10,2)
);

CREATE TABLE purchase_orders (
    po_id                    INTEGER PRIMARY KEY,
    sku                      VARCHAR(10) REFERENCES products(sku),
    supplier_id              INTEGER REFERENCES suppliers(supplier_id),
    order_date               DATE,
    promised_lead_time_days  INTEGER,
    actual_lead_time_days    INTEGER,
    received_date            DATE,
    qty_ordered              INTEGER
);

CREATE TABLE sales_orders (
    so_id            INTEGER PRIMARY KEY,
    sku              VARCHAR(10) REFERENCES products(sku),
    week_start_date  DATE,
    qty_demanded     INTEGER,
    qty_fulfilled    INTEGER,
    stockout_flag    INTEGER,
    ending_stock     INTEGER
);

-- Load data (run from psql, adjust path as needed; load parents before children):
-- \copy categories FROM 'categories.csv' WITH (FORMAT csv, HEADER true);
-- \copy suppliers FROM 'suppliers.csv' WITH (FORMAT csv, HEADER true);
-- \copy warehouses FROM 'warehouses.csv' WITH (FORMAT csv, HEADER true);
-- \copy products FROM 'products.csv' WITH (FORMAT csv, HEADER true);
-- \copy purchase_orders FROM 'purchase_orders.csv' WITH (FORMAT csv, HEADER true);
-- \copy sales_orders FROM 'sales_orders.csv' WITH (FORMAT csv, HEADER true);


/* ============================================================
   1. DATA VALIDATION
   ============================================================ */

SELECT 'categories' AS table_name, COUNT(*) FROM categories
UNION ALL SELECT 'suppliers', COUNT(*) FROM suppliers
UNION ALL SELECT 'warehouses', COUNT(*) FROM warehouses
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'purchase_orders', COUNT(*) FROM purchase_orders
UNION ALL SELECT 'sales_orders', COUNT(*) FROM sales_orders;

-- orphaned FKs (all should return 0 rows)
SELECT po.po_id FROM purchase_orders po
LEFT JOIN products p ON po.sku = p.sku WHERE p.sku IS NULL;

SELECT p.sku FROM products p
LEFT JOIN categories c ON p.category_id = c.category_id WHERE c.category_id IS NULL;

SELECT p.sku FROM products p
LEFT JOIN suppliers s ON p.supplier_id = s.supplier_id WHERE s.supplier_id IS NULL;

SELECT p.sku FROM products p
LEFT JOIN warehouses w ON p.warehouse_id = w.warehouse_id WHERE w.warehouse_id IS NULL;

-- impossible dates / negative stock (should return 0 rows)
SELECT * FROM purchase_orders WHERE received_date < order_date;
SELECT * FROM sales_orders WHERE ending_stock < 0;


/* ============================================================
   2. DESCRIPTIVE INVENTORY METRICS
   ============================================================ */

-- 2.1 Current snapshot: stock, weekly demand rate, days-of-supply per SKU
SELECT
    p.sku,
    c.category_name,
    p.starting_stock,
    ROUND(p.annual_units_sold / 52.0, 1)                              AS avg_weekly_demand,
    ROUND(p.starting_stock / NULLIF(p.annual_units_sold / 365.0, 0),1) AS days_of_supply
FROM products p
JOIN categories c ON p.category_id = c.category_id
ORDER BY days_of_supply ASC;

-- 2.2 Product count and total revenue by category
SELECT
    c.category_name,
    COUNT(*)                        AS num_skus,
    SUM(p.revenue_generated)        AS total_revenue,
    ROUND(AVG(p.revenue_generated),2) AS avg_revenue_per_sku
FROM products p
JOIN categories c ON p.category_id = c.category_id
GROUP BY c.category_name
ORDER BY total_revenue DESC;


/* ============================================================
   3. ABC CLASSIFICATION
   ============================================================ */

-- 3.1 Cumulative-% method (classic Pareto ABC)
WITH revenue_ranked AS (
    SELECT
        sku,
        revenue_generated,
        SUM(revenue_generated) OVER (ORDER BY revenue_generated DESC
                                      ROWS UNBOUNDED PRECEDING)         AS running_revenue,
        SUM(revenue_generated) OVER ()                                 AS total_revenue
    FROM products
)
SELECT
    sku,
    revenue_generated,
    ROUND(100.0 * running_revenue / total_revenue, 2) AS cumulative_pct,
    CASE
        WHEN 100.0 * running_revenue / total_revenue <= 70 THEN 'A'
        WHEN 100.0 * running_revenue / total_revenue <= 90 THEN 'B'
        ELSE 'C'
    END AS abc_tier
FROM revenue_ranked
ORDER BY revenue_generated DESC;

-- 3.2 Tier summary
WITH abc AS (
    SELECT sku, revenue_generated,
        ROUND(100.0 * SUM(revenue_generated) OVER (ORDER BY revenue_generated DESC
              ROWS UNBOUNDED PRECEDING) / SUM(revenue_generated) OVER (), 2) AS cum_pct
    FROM products
),
tiered AS (
    SELECT sku, revenue_generated,
        CASE WHEN cum_pct <= 70 THEN 'A' WHEN cum_pct <= 90 THEN 'B' ELSE 'C' END AS abc_tier
    FROM abc
)
SELECT
    abc_tier,
    COUNT(*)                                              AS num_skus,
    SUM(revenue_generated)                                AS tier_revenue,
    ROUND(100.0 * SUM(revenue_generated) /
        (SELECT SUM(revenue_generated) FROM products), 1) AS pct_of_total_revenue
FROM tiered
GROUP BY abc_tier
ORDER BY abc_tier;

-- 3.3 Cross-check with NTILE quartiles (revenue-based segmentation, alternate method)
SELECT
    sku,
    revenue_generated,
    NTILE(4) OVER (ORDER BY revenue_generated DESC) AS revenue_quartile
FROM products
ORDER BY revenue_generated DESC;


/* ============================================================
   4. REORDER POINT & SAFETY STOCK
   ============================================================ */

WITH demand_stats AS (
    SELECT sku,
        AVG(qty_demanded)     AS avg_weekly_demand,
        STDDEV(qty_demanded)  AS stddev_weekly_demand
    FROM sales_orders
    GROUP BY sku
),
leadtime_stats AS (
    SELECT sku,
        AVG(actual_lead_time_days) / 7.0    AS avg_lead_time_weeks,
        STDDEV(actual_lead_time_days) / 7.0 AS stddev_lead_time_weeks
    FROM purchase_orders
    GROUP BY sku
)
SELECT
    d.sku,
    ROUND(d.avg_weekly_demand, 1)                                   AS avg_weekly_demand,
    ROUND(l.avg_lead_time_weeks, 2)                                 AS avg_lead_time_weeks,
    ROUND(1.65 * COALESCE(d.stddev_weekly_demand,0) *
          SQRT(GREATEST(l.avg_lead_time_weeks,1)), 0)               AS safety_stock,
    ROUND(d.avg_weekly_demand * l.avg_lead_time_weeks +
          1.65 * COALESCE(d.stddev_weekly_demand,0) *
          SQRT(GREATEST(l.avg_lead_time_weeks,1)), 0)                AS reorder_point
FROM demand_stats d
JOIN leadtime_stats l ON d.sku = l.sku
ORDER BY reorder_point DESC;


/* ============================================================
   5. STOCKOUT ANALYSIS
   ============================================================ */

-- 5.1 Stockout frequency and lost units per SKU
SELECT
    sku,
    COUNT(*) FILTER (WHERE stockout_flag = 1)                 AS stockout_weeks,
    ROUND(100.0 * COUNT(*) FILTER (WHERE stockout_flag = 1) / COUNT(*), 1) AS stockout_rate_pct,
    SUM(qty_demanded - qty_fulfilled)                         AS total_units_lost
FROM sales_orders
GROUP BY sku
HAVING SUM(qty_demanded - qty_fulfilled) > 0
ORDER BY total_units_lost DESC;

-- 5.2 Estimated revenue lost to stockouts
SELECT
    s.sku,
    c.category_name,
    SUM(s.qty_demanded - s.qty_fulfilled)                          AS units_lost,
    ROUND(SUM(s.qty_demanded - s.qty_fulfilled) * p.price, 2)      AS est_revenue_lost
FROM sales_orders s
JOIN products p ON s.sku = p.sku
JOIN categories c ON p.category_id = c.category_id
GROUP BY s.sku, c.category_name, p.price
HAVING SUM(s.qty_demanded - s.qty_fulfilled) > 0
ORDER BY est_revenue_lost DESC
LIMIT 15;

-- 5.3 Gaps-and-islands: longest consecutive stockout streak per SKU
WITH flagged AS (
    SELECT sku, week_start_date, stockout_flag,
        ROW_NUMBER() OVER (PARTITION BY sku ORDER BY week_start_date)
          - ROW_NUMBER() OVER (PARTITION BY sku, stockout_flag ORDER BY week_start_date) AS grp
    FROM sales_orders
),
streaks AS (
    SELECT sku, grp, COUNT(*) AS streak_length
    FROM flagged
    WHERE stockout_flag = 1
    GROUP BY sku, grp
)
SELECT sku, MAX(streak_length) AS longest_stockout_streak_weeks
FROM streaks
GROUP BY sku
ORDER BY longest_stockout_streak_weeks DESC
LIMIT 15;


/* ============================================================
   6. SUPPLIER LEAD-TIME RELIABILITY
   ============================================================ */

-- 6.1 Actual vs promised lead time, variance, late-delivery rate by supplier
SELECT
    s.supplier_name,
    COUNT(*)                                                      AS total_pos,
    ROUND(AVG(po.promised_lead_time_days), 1)                     AS avg_promised_days,
    ROUND(AVG(po.actual_lead_time_days), 1)                       AS avg_actual_days,
    ROUND(STDDEV(po.actual_lead_time_days), 1)                    AS lead_time_stddev,
    ROUND(100.0 * COUNT(*) FILTER (WHERE po.actual_lead_time_days >
          po.promised_lead_time_days) / COUNT(*), 1)              AS late_delivery_rate_pct
FROM purchase_orders po
JOIN suppliers s ON po.supplier_id = s.supplier_id
GROUP BY s.supplier_name
ORDER BY lead_time_stddev DESC;

-- 6.2 Slowest products to arrive (ranked)
SELECT
    po.sku,
    s.supplier_name,
    ROUND(AVG(po.actual_lead_time_days), 1) AS avg_actual_lead_time,
    RANK() OVER (ORDER BY AVG(po.actual_lead_time_days) DESC) AS slowness_rank
FROM purchase_orders po
JOIN suppliers s ON po.supplier_id = s.supplier_id
GROUP BY po.sku, s.supplier_name
ORDER BY avg_actual_lead_time DESC
LIMIT 15;

-- 6.3 Trend: is each supplier's lead time getting worse over the year?
WITH ordered_pos AS (
    SELECT
        s.supplier_name,
        po.po_id,
        po.order_date,
        po.actual_lead_time_days,
        LAG(po.actual_lead_time_days) OVER (PARTITION BY s.supplier_name ORDER BY po.order_date) AS prev_lead_time
    FROM purchase_orders po
    JOIN suppliers s ON po.supplier_id = s.supplier_id
)
SELECT
    supplier_name,
    ROUND(AVG(actual_lead_time_days - prev_lead_time), 2) AS avg_change_vs_prior_po
FROM ordered_pos
WHERE prev_lead_time IS NOT NULL
GROUP BY supplier_name
ORDER BY avg_change_vs_prior_po DESC;


/* ============================================================
   7. CATEGORY & WAREHOUSE ROLLUPS
   ============================================================ */

-- 7.1 Inventory turnover ratio by category
SELECT
    c.category_name,
    ROUND(SUM(p.manufacturing_costs * p.annual_units_sold) /
          NULLIF(AVG(p.starting_stock * p.manufacturing_costs), 0), 2) AS turnover_ratio
FROM products p
JOIN categories c ON p.category_id = c.category_id
GROUP BY c.category_name
ORDER BY turnover_ratio DESC;

-- 7.2 Stockout rate by warehouse (which fulfillment center struggles most)
SELECT
    w.warehouse_name,
    w.city,
    COUNT(DISTINCT p.sku)                                              AS skus_assigned,
    ROUND(100.0 * SUM(so.stockout_flag) / COUNT(so.so_id), 1)          AS stockout_rate_pct
FROM sales_orders so
JOIN products p ON so.sku = p.sku
JOIN warehouses w ON p.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_name, w.city
ORDER BY stockout_rate_pct DESC;

-- 7.3 Shipping cost efficiency by carrier and mode
SELECT
    shipping_carriers,
    transportation_modes,
    COUNT(*)                          AS num_skus,
    ROUND(AVG(shipping_costs), 2)     AS avg_shipping_cost,
    ROUND(AVG(shipping_times), 1)     AS avg_shipping_time_days
FROM products
GROUP BY shipping_carriers, transportation_modes
ORDER BY avg_shipping_cost DESC;


/* ============================================================
   8. MONTHLY TREND ANALYSIS
   ============================================================ */

-- 8.1 Month-over-month stockout rate trend (is the problem getting better or worse?)
SELECT
    DATE_TRUNC('month', week_start_date)::date               AS month,
    COUNT(*)                                                  AS sku_weeks,
    ROUND(100.0 * SUM(stockout_flag) / COUNT(*), 1)           AS stockout_rate_pct,
    SUM(qty_demanded - qty_fulfilled)                         AS units_lost
FROM sales_orders
GROUP BY DATE_TRUNC('month', week_start_date)
ORDER BY month;

-- 8.2 Month-over-month change (window function comparing to prior month)
WITH monthly AS (
    SELECT
        DATE_TRUNC('month', week_start_date)::date AS month,
        ROUND(100.0 * SUM(stockout_flag) / COUNT(*), 1) AS stockout_rate_pct
    FROM sales_orders
    GROUP BY DATE_TRUNC('month', week_start_date)
)
SELECT
    month,
    stockout_rate_pct,
    stockout_rate_pct - LAG(stockout_rate_pct) OVER (ORDER BY month) AS change_vs_prior_month
FROM monthly
ORDER BY month;


/* ============================================================
   9. QUALITY CORRELATION ANALYSIS
   ============================================================ */

-- 9.1 Does a higher defect rate associate with more stockouts?
--     (bucket products into defect-rate quartiles, compare avg stockout rate)
WITH defect_quartiles AS (
    SELECT
        sku,
        defect_rate_pct,
        NTILE(4) OVER (ORDER BY defect_rate_pct) AS defect_quartile
    FROM products
),
stockout_by_sku AS (
    SELECT sku, ROUND(100.0 * SUM(stockout_flag) / COUNT(*), 1) AS stockout_rate_pct
    FROM sales_orders
    GROUP BY sku
)
SELECT
    dq.defect_quartile,
    ROUND(AVG(dq.defect_rate_pct), 2)   AS avg_defect_rate_in_quartile,
    ROUND(AVG(sbs.stockout_rate_pct), 1) AS avg_stockout_rate_pct
FROM defect_quartiles dq
JOIN stockout_by_sku sbs ON dq.sku = sbs.sku
GROUP BY dq.defect_quartile
ORDER BY dq.defect_quartile;

-- 9.2 Inspection result vs. supplier lead-time variance
SELECT
    p.inspection_results,
    COUNT(DISTINCT p.sku)                              AS num_skus,
    ROUND(AVG(po_stats.lead_time_stddev), 2)            AS avg_supplier_lead_time_stddev
FROM products p
JOIN (
    SELECT sku, STDDEV(actual_lead_time_days) AS lead_time_stddev
    FROM purchase_orders
    GROUP BY sku
) po_stats ON p.sku = po_stats.sku
GROUP BY p.inspection_results
ORDER BY avg_supplier_lead_time_stddev DESC;


/* ============================================================
   10. SYNTHESIS: PRIORITIZED RISK QUERIES
   ============================================================ */

-- 10.1 Combine ABC tier + stockout risk + supplier reliability into one risk flag
WITH abc AS (
    SELECT sku, revenue_generated,
        CASE WHEN ROUND(100.0 * SUM(revenue_generated) OVER (ORDER BY revenue_generated DESC
             ROWS UNBOUNDED PRECEDING) / SUM(revenue_generated) OVER (), 2) <= 70 THEN 'A'
             WHEN ROUND(100.0 * SUM(revenue_generated) OVER (ORDER BY revenue_generated DESC
             ROWS UNBOUNDED PRECEDING) / SUM(revenue_generated) OVER (), 2) <= 90 THEN 'B'
             ELSE 'C' END AS abc_tier
    FROM products
),
stockout_summary AS (
    SELECT sku,
        ROUND(100.0 * COUNT(*) FILTER (WHERE stockout_flag = 1) / COUNT(*), 1) AS stockout_rate_pct
    FROM sales_orders
    GROUP BY sku
),
supplier_reliability AS (
    SELECT p.sku,
        ROUND(STDDEV(po.actual_lead_time_days), 1) AS supplier_lead_time_stddev
    FROM products p
    JOIN purchase_orders po ON p.sku = po.sku
    GROUP BY p.sku
)
SELECT
    a.sku,
    a.abc_tier,
    s.stockout_rate_pct,
    sr.supplier_lead_time_stddev,
    CASE
        WHEN a.abc_tier = 'A' AND s.stockout_rate_pct > 10 AND sr.supplier_lead_time_stddev > 3
            THEN 'HIGH RISK - review supplier + safety stock'
        WHEN a.abc_tier = 'A' AND s.stockout_rate_pct > 10
            THEN 'MODERATE RISK - demand outpacing stock'
        WHEN a.abc_tier = 'A' AND sr.supplier_lead_time_stddev > 3
            THEN 'MODERATE RISK - unreliable supplier on key SKU'
        ELSE 'LOW RISK'
    END AS risk_flag
FROM abc a
JOIN stockout_summary s ON a.sku = s.sku
JOIN supplier_reliability sr ON a.sku = sr.sku
WHERE a.abc_tier = 'A'
ORDER BY s.stockout_rate_pct DESC, sr.supplier_lead_time_stddev DESC;

-- 10.2 Warehouse + category cross-tab of stockout risk (where should ops focus first)
SELECT
    w.city,
    c.category_name,
    COUNT(DISTINCT p.sku)                                     AS num_skus,
    ROUND(100.0 * SUM(so.stockout_flag) / COUNT(so.so_id), 1) AS stockout_rate_pct
FROM sales_orders so
JOIN products p ON so.sku = p.sku
JOIN warehouses w ON p.warehouse_id = w.warehouse_id
JOIN categories c ON p.category_id = c.category_id
GROUP BY w.city, c.category_name
ORDER BY stockout_rate_pct DESC
LIMIT 10;
