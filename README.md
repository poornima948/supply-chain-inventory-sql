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
Overall stockout rate came out to 6.2% of SKU-weeks — meaning demand outpaced available stock about 1 out of every 16 weeks across the catalog. For the 15 worst-affected SKUs alone, that translates to roughly $130K in lost revenue, which is the kind of number that's easy to miss if you're only looking at current stock levels rather than the order history.

Supplier reliability turned out to be a bigger factor than I expected. Lead-time standard deviation across the 5 suppliers ranges from about 7 days on the more consistent end up to 9.4 days for the least predictable one — so two suppliers with similar average lead times can require very different safety stock buffers depending on how erratic they actually are.

The warehouse-level breakdown was the most useful cut for me: Delhi and Mumbai are running stockout rates around 9%, while Kolkata sits under 3%. That's a clearer signal for where to focus than any single SKU-level number, since it points at operational/fulfillment issues rather than just demand forecasting.

Stockout rate also isn't flat over the year — it spiked early on, dropped, then climbed back up through the later months before easing off again. That pattern only shows up because of the added time dimension; the original flat dataset had no way to show it.

One thing that didn't pan out: I expected defect rate to correlate with stockouts (bad batches → more return/rework → less available stock), but breaking SKUs into defect-rate quartiles showed no consistent relationship. Worth noting as a negative result — it points more toward demand volatility and supplier timing as the real drivers here, not product quality.

Combining ABC tier, stockout rate, and supplier variance into one query flags a short list of top-revenue SKUs that need attention first, instead of leaving it as 100 separate numbers to sort through manually.

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
The original Kaggle dataset is a single flat snapshot — no order history, no time dimension — so questions like "how often do we stock out" or "is a supplier getting worse" couldn't be answered with it directly. I normalized it into separate `categories`/`suppliers`/`warehouses`/`products` tables and generated a 52-week purchase and sales history on top of it, keeping every real attribute from the original data (price, lead time, stock levels, order quantities) as the basis for the simulation rather than inventing numbers unrelated to it. This is a reasonable approach when a public dataset covers the right entities but is missing the time-series depth a specific analysis needs.
