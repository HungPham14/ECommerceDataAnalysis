/*
Document: https://docs.google.com/document/d/1ggGtqyOV4OBD9uK7zT3QZTOo3YQfse1Q7nhs_viGhQI
*/
DECLARE cut_off_time DATE;
DECLARE threshold FLOAT64;

SET cut_off_time = DATE(CURRENT_DATE('+7') - INTERVAL 6 MONTH);
SET threshold = 0.6;

CREATE TEMP FUNCTION jaccard_similarity(s1 STRING, s2 STRING)
RETURNS FLOAT64
LANGUAGE js AS """
  const tokenize = str => new Set(str.toLowerCase().split(/\\s+/).filter(Boolean));

  const set1 = tokenize(s1);
  const set2 = tokenize(s2);

  const intersection = new Set([...set1].filter(x => set2.has(x)));
  const union = new Set([...set1, ...set2]);

  if (union.size === 0) return 0;

  return intersection.size / union.size;
""";

WITH sku_1p_tab AS (
  SELECT
    sku,
    pmaster_sku,
    product_name,
    list_price,
    cate2_id
  FROM `tiki-dwh.dwh.dim_product_full`
  WHERE TRUE
    AND COALESCE(is_free_gift, FALSE) = FALSE
    AND business_type IN ('1P')
    AND entity_type = 'seller_simple'
    AND is_salable IS TRUE
    AND sub_cate_report IN ('Book & Office Supplies')
    AND (cate2 IN ('Sách tiếng Việt', 'English Books') OR cate3 IN ('Sách tiếng Việt', 'English Books'))
    AND sale_price > 0
)

, pmaster_1p_tab AS (
  SELECT DISTINCT
    pmaster_sku
  FROM sku_1p_tab
)

, sku_3p_tab AS (
  SELECT
    sku,
    pmaster_sku,
    product_name,
    product_key,
    COALESCE(
      CONCAT('https://tiki.vn/', url_path), 
      CONCAT(
        'https://tiki.vn/',
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            LOWER(
              NORMALIZE(product_name, NFD)
            ),
            r'[^a-z0-9\s-]', ''  -- Remove special characters
          ),
          r'[\s]+', '-'  -- Replace spaces with hyphens
        ),
        '-p',
        pmaster_id,
        '.html?spid=',
        product_key)
    ) AS url_path,
    list_price,
    sale_price,
    cate2_id,
    seller_name,
    sub_cate_report,
  FROM `tiki-dwh.dwh.dim_product_full`
  WHERE TRUE
    AND COALESCE(is_free_gift, FALSE) = FALSE
    AND business_type IN ('3P-Local', '3P-CB')
    AND entity_type = 'seller_simple'
    AND is_salable IS TRUE
    AND sub_cate_report IN ('Book & Office Supplies')
    AND (cate2 IN ('Sách tiếng Việt', 'English Books') OR cate3 IN ('Sách tiếng Việt', 'English Books'))
    -- AND cate2 IN ('Văn phòng phẩm', 'Quà lưu niệm')
    AND sale_price > 0
)

, pdp_3p_tab AS (
  SELECT
    s.sku,
    COUNT(p.client_id) AS pdp_view
  FROM `tiki-dwh.trackity_tiki.pdp` AS p
  JOIN sku_3p_tab AS s ON p.sku = s.sku
  WHERE TRUE
    AND p.event_name = 'view'
    AND p.date_key >= cut_off_time
    AND p.date_key <= CURRENT_DATE('+7')
  GROUP BY ALL
)

, order_3p_tab AS (
  SELECT
    s.sku,
    COUNT(DISTINCT CASE WHEN n.order_type IN (1) THEN n.order_code ELSE NULL END)
    - COUNT(DISTINCT CASE WHEN n.order_type IN (2, 3) THEN n.order_code ELSE NULL END) AS order_count,
    SUM(CASE WHEN n.order_type IN (1) THEN n.quantity ELSE 0 END)
    - SUM(CASE WHEN n.order_type IN (2,3) THEN -n.quantity ELSE 0 END) AS quantity,
    COUNT(DISTINCT CASE WHEN n.order_type IN (2) THEN n.order_code ELSE NULL END) AS cancelled_order_count
  FROM `tiki-dwh.nmv.nmv` AS n
  JOIN sku_3p_tab AS s ON n.sku = s.sku
  WHERE TRUE
    AND n.platform <> 'external'
    AND LOWER(n.sale_channel) = 'online'
    AND n.date >= cut_off_time
    AND n.date <= CURRENT_DATE('+7')
  GROUP BY ALL
  HAVING order_count > 0
)

, review_3p_tab AS (
  SELECT
    s.sku,
    AVG(r.rating) AS avg_rating,
    COUNT(r.id) AS rating_count
  FROM `tiki-dwh.ecom.review` AS r
  JOIN sku_3p_tab AS s ON r.spid = s.product_key
  WHERE TRUE
    -- AND DATE(DATETIME(r.created_at, '+7')) >= CURRENT_DATE('+7') - INTERVAL 12 MONTH
    -- AND DATE(DATETIME(r.created_at, '+7')) <= CURRENT_DATE('+7')
  GROUP BY ALL
)

, final_sku_3p_tab AS (
  SELECT
    s3.*,
    o3.order_count,
    p3.pdp_view,
    r3.avg_rating,
    r3.rating_count,
    SAFE_DIVIDE(o3.order_count, p3.pdp_view) AS cr,
    o3.quantity,
    o3.cancelled_order_count
  FROM sku_3p_tab AS s3
  JOIN order_3p_tab AS o3 ON s3.sku = o3.sku
  JOIN pdp_3p_tab AS p3 ON s3.sku = p3.sku
  LEFT JOIN review_3p_tab AS r3 ON s3.sku = r3.sku
  WHERE TRUE
    AND (r3.avg_rating IS NULL OR r3.avg_rating >= 4)
  GROUP BY ALL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pmaster_sku ORDER BY order_count DESC, pdp_view DESC, avg_rating DESC, rating_count DESC, cr DESC) = 1
)

, pre_final AS (
  SELECT
    s3.*,
    s1.product_name AS product_name_1p,
  FROM final_sku_3p_tab AS s3
  LEFT JOIN sku_1p_tab AS s1 ON s3.cate2_id = s1.cate2_id
    AND s3.list_price <= s1.list_price * 1.1
    AND s3.list_price >= s1.list_price * 0.9
  LEFT JOIN pmaster_1p_tab AS p1p ON s3.pmaster_sku = p1p.pmaster_sku
  WHERE TRUE
    AND p1p.pmaster_sku IS NULL
  GROUP BY ALL
)

, final AS (
  SELECT DISTINCT
    *,
    jaccard_similarity(COALESCE(product_name, 'null'), COALESCE(product_name_1p, 'null')) AS similarity_score,
  FROM pre_final
  WHERE TRUE
)

, BOOK_FINAL AS (
  SELECT DISTINCT
    f.* EXCEPT(pmaster_sku, cate2_id, product_name_1p, similarity_score, seller_name, sub_cate_report),
    f.seller_name,
    f.sub_cate_report
  FROM final AS f
  LEFT JOIN `tiki-dwh.commercial_report.mkt__ggs_3p_book_push_gg_ads_removed` AS r ON f.sku = r.sku
    AND r.note IS NOT NULL
  WHERE TRUE
    AND r.note IS NULL 
  QUALIFY MAX(similarity_score) OVER(PARTITION BY sku) < threshold
  ORDER BY order_count DESC, pdp_view DESC, avg_rating DESC, rating_count DESC, cr DESC, quantity DESC, cancelled_order_count ASC
  LIMIT 100
)

SELECT * FROM BOOK_FINAL
