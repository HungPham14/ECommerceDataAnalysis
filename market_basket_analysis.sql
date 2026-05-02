/*
Tình huống (Nếu không dùng Lift):
Bạn đo lường thấy 90% người mua Bỉm (A) thì giỏ hàng của họ cũng có Sữa tươi (B). 
Bạn đinh ninh rằng Confidence = 90% là quá cao, liền cài đặt gợi ý: "Ai mua Bỉm thì gợi ý Sữa tươi".
Nhưng bạn quên mất một điều: Sữa tươi là thứ mà không mua bỉm người ta vẫn mua. 
Việc khách mua Bỉm chả tác động gì đến việc họ mua Sữa cả. 
Việc gợi ý Sữa tươi lúc này là lãng phí không gian hiển thị!

Giải pháp (Sự xuất hiện của Lift):
Lift sinh ra để trả lời câu hỏi: "Việc khách mua món A có THỰC SỰ thúc đẩy họ mua món B không, hay chỉ là do món B vốn dĩ đã bán quá chạy?"
$$Lift = \frac{\text{Xác suất khách mua cả A và B}}{\text{Xác suất mua A} \times \text{Xác suất mua B}}$$
Cách đọc chỉ số Lift:
Lift = 1: Mua A và mua B hoàn toàn độc lập. (Như việc mua Bỉm và Sữa tươi ở trên). Đừng gợi ý chéo!
Lift < 1: Khách mua A thì sẽ giảm khả năng mua B. (Ví dụ: Khách mua Coca thì khả năng cao sẽ không mua Pepsi nữa). Đây là các sản phẩm thay thế (Substitutes), không được Cross-sell cùng nhau.
Lift > 1: ĐÂY LÀ CHÂN ÁI! Mua A làm tăng vọt khả năng mua B. (Ví dụ: Khách mua Bỉm thì mua Bia. Có thể do các ông bố đi mua bỉm cho con thường tiện tay xách luôn lốc bia). 
Lift càng cao, mối liên hệ càng chặt chẽ.
*/

WITH 
user_events_cte AS (
  SELECT DISTINCT 
    customer_id, session.session_id, p.product_id, event_name, event_time,
    device.os_name, device.device_type, device.browser_name,
    traffic_source.utm_source, traffic_source.utm_medium, traffic_source.utm_campaign
  FROM `tiki-dwh.trackity.tiki_events_sessions`, UNNEST(products) AS p
  WHERE date_key BETWEEN '2026-02-01' AND '2026-03-01'
)

, products_cte AS (
  SELECT DISTINCT
    product_key,
    sub_cate_report,
    product_name,
    sale_price
  FROM `tiki-dwh.dwh.dim_product_full`
  WHERE 1=1
  AND last_updated_at >= '2025-01-01'
  -- [FIX 1] ĐIỀU KIỆN SẢN PHẨM: Chỉ lấy hàng Đang/Có thể kinh doanh
  AND is_salable = TRUE 
  -- [FIX 2.1] LỌC GIFT: Loại bỏ các item có chữ "quà tặng" (nếu tên chuẩn hóa tốt)
  AND LOWER(product_name) NOT LIKE '%quà tặng%' 
  AND LOWER(product_name) NOT LIKE '%gift%' 
  AND LOWER(product_name) NOT LIKE '%hàng tặng không bán%' 
)

, orders_cte AS (
  SELECT 
    original_code,
    customer_id_fe,
    SUM(CASE WHEN order_type = 1 THEN amount ELSE 0 END) - SUM(CASE WHEN order_type IN (2,3) THEN amount ELSE 0 END) AS amount,
    MIN(created_at) AS created_at
  FROM `tiki-dwh.nmv.nmv`
  WHERE DATE(created_at) BETWEEN '2026-02-01' AND '2026-03-01'
  AND order_type IN (1,2,3)
  AND sale_channel = 'online' AND platform != 'external'
  GROUP BY ALL
  HAVING amount > 0
)

, order_items_cte AS (
  SELECT 
    CONCAT(original_code,' - ',product_id) AS order_item_id,
    original_code,
    product_id,
    SUM(CASE WHEN order_type = 1 THEN quantity ELSE 0 END) - SUM(CASE WHEN order_type IN (2,3) THEN quantity ELSE 0 END) AS sold_quantity_net,
    MIN(price) AS price
  FROM `tiki-dwh.nmv.nmv`  
  -- LEFT JOIN 
  WHERE DATE(created_at) BETWEEN '2026-02-01' AND '2026-03-01'
    AND order_type IN (1,2,3)
    AND sale_channel = 'online' AND platform != 'external'
    AND product_id IS NOT NULL
    -- [FIX 2.2] LỌC GIFT: Loại bỏ toàn bộ sản phẩm có giá = 0 (thường là hàng tặng kèm trong combo)
    AND price > 0 
    -- AND LOWER(product_name) NOT LIKE '%gift%'
  GROUP BY ALL
)

, total_orders_cte AS (
  SELECT COUNT(DISTINCT original_code) AS total_orders FROM orders_cte
)

, item_frequency_cte AS (
  SELECT product_id, COUNT(DISTINCT original_code) AS item_order_count
  FROM order_items_cte WHERE sold_quantity_net > 0 GROUP BY 1
)

, item_pairs_cte AS (
  SELECT 
    a.product_id AS item_A, b.product_id AS item_B,
    COUNT(DISTINCT a.original_code) AS pair_order_count
  FROM order_items_cte a
  JOIN order_items_cte b ON a.original_code = b.original_code AND a.product_id != b.product_id
  WHERE a.sold_quantity_net > 0 AND b.sold_quantity_net > 0
  GROUP BY 1, 2
)

SELECT 
  p.item_A, prod_A.product_name AS name_A,
  p.item_B, prod_B.product_name AS name_B,
  p.pair_order_count,
  (p.pair_order_count / t.total_orders) AS support,
  (p.pair_order_count / freq_A.item_order_count) AS confidence,
  (p.pair_order_count / freq_A.item_order_count) / (freq_B.item_order_count / t.total_orders) AS lift
FROM item_pairs_cte p
CROSS JOIN total_orders_cte t
JOIN item_frequency_cte freq_A ON p.item_A = freq_A.product_id
JOIN item_frequency_cte freq_B ON p.item_B = freq_B.product_id

-- [FIX 3] THAY ĐỔI LOGIC JOIN: Đổi từ LEFT JOIN sang INNER JOIN
-- Vì bảng products_cte đã được lọc sạch (chỉ còn hàng is_salable = TRUE và không phải Gift).
-- Khi dùng INNER JOIN, bất kỳ bộ đôi Item A hoặc Item B nào là Gift/Ngừng kinh doanh sẽ bị thuật toán tự động vứt bỏ khỏi kết quả cuối cùng.
JOIN products_cte prod_A ON CAST(p.item_A AS STRING) = CAST(prod_A.product_key AS STRING)
JOIN products_cte prod_B ON CAST(p.item_B AS STRING) = CAST(prod_B.product_key AS STRING)

WHERE p.pair_order_count >= 5 
  AND ( (p.pair_order_count / freq_A.item_order_count) / (freq_B.item_order_count / t.total_orders) ) > 1.2
ORDER BY lift DESC, confidence DESC;
