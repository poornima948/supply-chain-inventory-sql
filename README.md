# Supply Chain & Inventory Optimization — SQL Project

## Problem Statement
Businesses lose money two ways with inventory: **holding too much** (cash tied up, storage cost) or **holding too little** (stockouts, lost sales, unhappy customers). This project answers the questions a supply chain / operations team actually asks:

1. **Which products matter most?** → ABC classification ranks SKUs by revenue contribution.
2. **Where are we losing sales to stockouts, and how much revenue is that costing?** → Stockout analysis, including how the problem trends month over month.
3. **Which suppliers can we actually rely on?** → Supplier lead-time reliability analysis separates consistently fast suppliers from consistently unpredictable ones.
4. **Where should ops focus first?** → City/warehouse and category-level rollups pinpoint which fulfillment centers and product lines are highest-risk.

The project closes with a **synthesis query** that combines ABC tier, stockout rate, and supplier reliability into a single prioritized risk list.

## Dataset
- **Base data:** Kaggle Supply Chain Dataset — 100 SKUs across haircare, skincare, and cosmetics, with pricing, supplier, shipping, and manufacturing attributes.
- **Normalization:** the original dataset is a single flat table. It was normalized into a proper relational schema (`categories`, `suppliers`, `warehouses`, `products`) and extended with a synthetic 52-week order history so time-based analysis is possible:
  - `purchase_orders.csv` — 1,288 supplier orders, with **actual lead time simulated per supplier** (each supplier has its own reliability profile) so variance-based queries (`STDDEV`, `LAG` trend) reflect genuine supplier differences.
  - `sales_orders.csv` — 5,200 weekly demand records, with **stock simulated as a running weekly balance**. Stockouts emerge from the simulation rather than being hardcoded.

## Schema
```
categories   (category_id PK, category_name)
suppliers    (supplier_id PK, supplier_name, hq_location)
warehouses   (warehouse_id PK, warehouse_name, city)
products     (sku PK, category_id FK, supplier_id FK, warehouse_id FK, price, ...)
purchase_orders (po_id PK, sku FK, supplier_id FK, order_date, promised_lead_time_days,
                  actual_lead_time_days, received_date, qty_ordered)
sales_orders    (so_id PK, sku FK, week_start_date, qty_demanded, qty_fulfilled,
                  stockout_flag, ending_stock)
```

## Tech Stack
PostgreSQL · window functions (`SUM() OVER`, `RANK()`, `LAG()`, `NTILE()`) · CTEs · gaps-and-islands technique · `FILTER` clauses · `DATE_TRUNC` time-series rollups

## Key Findings
- **Overall stockout rate: 6.2%** of SKU-weeks saw demand exceed available stock.
- **Estimated revenue lost to stockouts (top 15 affected SKUs): ~$130K+**.
- **Supplier reliability varies meaningfully**: lead-time standard deviation ranges from **7.0 days** (most consistent suppliers) to **9.4 days** (least consistent) — a ~35% reliability gap that matters more for planning buffers than average lead time alone.
- **Stockout risk is not evenly distributed geographically**: the Delhi and Mumbai fulfillment centers run stockout rates of **9.0–9.1%**, more than 3x the Kolkata center's **2.6%** — a concrete, actionable finding for where to prioritize inventory investment.
- **Stockout rate trended down from a 9.0% peak in month 1 to under 3% by month 2**, then drifted back up to ~7-8% through the winter months before improving again — visible only because of the time-series extension, not something the original flat dataset could show.
- **Defect rate does not meaningfully correlate with stockout rate** in this data (quartile analysis shows no consistent upward trend) — a legitimate negative finding: it rules out product quality as a driver of stockouts here, pointing attention back to demand volatility and supplier lead time instead.
- The synthesis query flags a short list of **A-tier (top-revenue) SKUs as HIGH or MODERATE RISK**, combining stockout rate and supplier unreliability into one prioritized action list instead of 100 SKUs to sift through manually.

## How to Run
1. Run the DDL in `sql/supply_chain_analysis.sql` (Section 0) to create all 6 tables.
2. Load the CSVs **in this order** (parents before children, since FKs enforce it):
   ```sql
   \copy categories FROM 'categories.csv' WITH (FORMAT csv, HEADER true);
   \copy suppliers FROM 'suppliers.csv' WITH (FORMAT csv, HEADER true);
   \copy warehouses FROM 'warehouses.csv' WITH (FORMAT csv, HEADER true);
   \copy products FROM 'products.csv' WITH (FORMAT csv, HEADER true);
   \copy purchase_orders FROM 'purchase_orders.csv' WITH (FORMAT csv, HEADER true);
   \copy sales_orders FROM 'sales_orders.csv' WITH (FORMAT csv, HEADER true);
   ```
3. Run Section 1 (validation queries) to confirm row counts and referential integrity.
4. Run Sections 2–10 for the full analysis, in order.

## Repository Structure
```
/data
  categories.csv
  suppliers.csv
  warehouses.csv
  products.csv
  purchase_orders.csv
  sales_orders.csv
/sql
  supply_chain_analysis.sql
/erd
  schema_diagram.png
README.md
```

## Notes on Methodology
The relational normalization and order-history extension are clearly synthetic and documented as such — generated to preserve every real attribute in the base dataset while adding the structural and temporal depth (foreign keys, order history) needed to answer real supply-chain questions. This is a standard, defensible technique when a public dataset is flat or lacks the time dimension a business question requires.
