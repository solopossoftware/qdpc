-- ================================================================
--  OPTIONAL — tidy the Store database after Production moved to the Production app
--  The Store app no longer uses these tables. Old Store production vouchers are NOT copied
--  to the Production app. Skip this script if you want to keep the old records for reference.
--  !! DESTRUCTIVE: permanently deletes old Store production orders.
-- ================================================================
drop view if exists v_pending_approvals cascade;
create view v_pending_approvals as
select 'grn' as type, id, grn_no as voucher_no, warehouse_id, date, status, submitted_by, created_at from purchases where status='Pending Approval'
union all select 'gin', id, gin_no, warehouse_id, date, status, submitted_by, created_at from gin_vouchers where status='Pending Approval'
union all select 'transfer', id, trn_no, from_warehouse_id, date, status, submitted_by, created_at from stock_transfers where status='Pending Approval'
union all select 'con', id, con_no, warehouse_id, date, status, submitted_by, created_at from consumption_vouchers where status='Pending Approval'
union all select 'mr', id, mr_no, warehouse_id, date, status, submitted_by, created_at from material_requests where status='Pending Approval'
union all select 'dmg', id, dmg_no, warehouse_id, date, status, submitted_by, created_at from damaged_products where status='Pending Approval';

drop table if exists production_raw_materials cascade;
drop table if exists production_outputs       cascade;
drop table if exists production_orders        cascade;
notify pgrst, 'reload schema';
