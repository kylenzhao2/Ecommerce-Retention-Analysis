-- =====================================================================
-- E-Commerce Customer Retention & Churn Analysis
-- BigQuery Standard SQL
-- Tables: `project.dataset.customers`, `.orders`, `.products`, `.order_items`
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. First purchase date per customer
-- Purpose: establishes when each customer started as a buyer.
-- Foundation for cohort analysis (query 2).
-- ---------------------------------------------------------------------
SELECT
  c.customer_id,
  MIN(o.order_date) AS first_order_date
FROM `project.dataset.customers` c
JOIN `project.dataset.orders` o
  ON c.customer_id = o.customer_id
WHERE o.status = 'completed'
GROUP BY c.customer_id;


-- ---------------------------------------------------------------------
-- 2. Monthly cohort retention
-- Purpose: groups customers by first-purchase month, tracks how many
-- are still ordering N months later.
-- Finding: 64% of customers churn by month 1.
-- ---------------------------------------------------------------------
WITH first_purchase AS (
  SELECT
    customer_id,
    DATE_TRUNC(MIN(order_date), MONTH) AS cohort_month
  FROM `project.dataset.orders`
  WHERE status = 'completed'
  GROUP BY customer_id
),
orders_with_cohort AS (
  SELECT
    o.customer_id,
    fp.cohort_month,
    DATE_DIFF(DATE_TRUNC(o.order_date, MONTH), fp.cohort_month, MONTH) AS month_number
  FROM `project.dataset.orders` o
  JOIN first_purchase fp USING (customer_id)
  WHERE o.status = 'completed'
)
SELECT
  cohort_month,
  month_number,
  COUNT(DISTINCT customer_id) AS active_customers
FROM orders_with_cohort
GROUP BY cohort_month, month_number
ORDER BY cohort_month, month_number;


-- ---------------------------------------------------------------------
-- 3. RFM segmentation (Recency, Frequency, Monetary)
-- Purpose: scores customers on purchase behavior, assigns segments.
-- Finding: At-Risk segment holds 31% of total revenue ($685K).
-- ---------------------------------------------------------------------
WITH rfm_base AS (
  SELECT
    customer_id,
    DATE_DIFF(DATE('2025-12-31'), MAX(order_date), DAY) AS recency_days,
    COUNT(DISTINCT order_id) AS frequency,
    SUM(order_total) AS monetary
  FROM `project.dataset.orders`
  WHERE status = 'completed'
  GROUP BY customer_id
),
rfm_scored AS (
  SELECT
    customer_id, recency_days, frequency, monetary,
    NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
    NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
    NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
  FROM rfm_base
)
SELECT *,
  CASE
    WHEN r_score >= 4 AND f_score >= 4 THEN 'Champions'
    WHEN r_score >= 4 AND f_score < 4 THEN 'New / Promising'
    WHEN r_score BETWEEN 2 AND 3 AND f_score >= 3 THEN 'At Risk'
    WHEN r_score <= 2 AND f_score <= 2 THEN 'Lost'
    ELSE 'Needs Attention'
  END AS segment
FROM rfm_scored
ORDER BY monetary DESC;


-- ---------------------------------------------------------------------
-- 4. Customer lifetime value (CLV) by acquisition channel
-- Purpose: compares customer value across acquisition channels.
-- Finding: email has highest CLV ($806) and order frequency (2.59).
-- ---------------------------------------------------------------------
SELECT
  c.acquisition_channel,
  COUNT(DISTINCT c.customer_id) AS customers,
  COUNT(DISTINCT o.order_id) AS total_orders,
  ROUND(SUM(o.order_total), 2) AS total_revenue,
  ROUND(SUM(o.order_total) / COUNT(DISTINCT c.customer_id), 2) AS avg_clv
FROM `project.dataset.customers` c
LEFT JOIN `project.dataset.orders` o
  ON c.customer_id = o.customer_id AND o.status = 'completed'
GROUP BY c.acquisition_channel
ORDER BY avg_clv DESC;


-- ---------------------------------------------------------------------
-- 5. Month-over-month revenue growth
-- Purpose: tracks total monthly revenue and % change vs. prior month.
-- Finding: rapid growth in 2023, plateau in 2024-2025.
-- ---------------------------------------------------------------------
WITH monthly AS (
  SELECT
    DATE_TRUNC(order_date, MONTH) AS month,
    SUM(order_total) AS revenue
  FROM `project.dataset.orders`
  WHERE status = 'completed'
  GROUP BY month
)
SELECT
  month, revenue,
  LAG(revenue) OVER (ORDER BY month) AS prev_month_revenue,
  ROUND(SAFE_DIVIDE(revenue - LAG(revenue) OVER (ORDER BY month),
                     LAG(revenue) OVER (ORDER BY month)) * 100, 1) AS mom_growth_pct
FROM monthly
ORDER BY month;


-- ---------------------------------------------------------------------
-- 6. Refund/cancellation rate by product category
-- Purpose: checks whether churn correlates with product-quality issues.
-- Finding: issue rates are flat across categories (13.9%-15.8%) -
-- rules out product quality as a churn driver.
-- ---------------------------------------------------------------------
SELECT
  p.category,
  COUNT(*) AS total_line_items,
  COUNTIF(o.status = 'refunded') AS refunded_items,
  COUNTIF(o.status = 'cancelled') AS cancelled_items,
  ROUND(COUNTIF(o.status IN ('refunded','cancelled')) / COUNT(*) * 100, 2) AS issue_rate_pct
FROM `project.dataset.order_items` oi
JOIN `project.dataset.orders` o ON oi.order_id = o.order_id
JOIN `project.dataset.products` p ON oi.product_id = p.product_id
GROUP BY p.category
ORDER BY issue_rate_pct DESC;
