-- ================================================================
--  BIZPOZ — Complete Migration Script
--  Run this ONCE in Supabase → SQL Editor
--  Safe to run multiple times (uses IF NOT EXISTS / IF NOT EXISTS)
-- ================================================================

-- ── 1. settings: add company profile columns ──────────────────
alter table settings
  add column if not exists address      text,
  add column if not exists phone        text,
  add column if not exists email        text,
  add column if not exists tax_no       text,
  add column if not exists company_logo text;

-- ── 2. items: add sub_category column ─────────────────────────
alter table items
  add column if not exists sub_category text;

-- ── 3. warehouses: add parent_id (for future use) ─────────────
alter table warehouses
  add column if not exists parent_id uuid references warehouses(id) on delete set null;

-- ── 4. purchases: add total_items ─────────────────────────────
alter table purchases
  add column if not exists total_items integer not null default 0;

-- ── 5. stock_transfers: add total_items ───────────────────────
alter table stock_transfers
  add column if not exists total_items integer not null default 0;

-- ── 6. production_orders: add total_items ─────────────────────
alter table production_orders
  add column if not exists total_items integer not null default 0;

-- ── 7. Backfill total_items for existing records ──────────────

-- Purchases: count from purchase_items
update purchases p
set total_items = (
  select count(*) from purchase_items pi where pi.purchase_id = p.id
)
where total_items = 0;

-- Stock Transfers: count from transfer_items
update stock_transfers t
set total_items = (
  select count(*) from transfer_items ti where ti.transfer_id = t.id
)
where total_items = 0;

-- Production Orders: count raw materials + outputs
update production_orders po
set total_items = (
  coalesce((select count(*) from production_raw_materials rm where rm.production_id = po.id), 0) +
  coalesce((select count(*) from production_outputs op where op.production_id = po.id), 0)
)
where total_items = 0;

-- ── 8. Refresh PostgREST schema cache ─────────────────────────
notify pgrst, 'reload schema';

-- ── 9. Verify ─────────────────────────────────────────────────
select
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_name in ('settings','items','warehouses','purchases','stock_transfers','production_orders')
  and column_name in ('address','phone','email','tax_no','company_logo',
                       'sub_category','parent_id','total_items')
order by table_name, column_name;

-- ================================================================
-- Expected: 9 rows —
--   items            | sub_category  | text    | YES | null
--   production_orders| total_items   | integer | NO  | 0
--   purchases        | total_items   | integer | NO  | 0
--   settings         | address       | text    | YES | null
--   settings         | company_logo  | text    | YES | null
--   settings         | email         | text    | YES | null
--   settings         | phone         | text    | YES | null
--   settings         | tax_no        | text    | YES | null
--   stock_transfers  | total_items   | integer | NO  | 0
--   warehouses       | parent_id     | uuid    | YES | null
-- ================================================================

-- ================================================================
--  Migration v4 — Categories + Warehouse Groups tables
--  These were previously localStorage-only — now synced to Supabase
-- ================================================================

-- ── Categories table ──────────────────────────────────────────
create table if not exists categories (
  id          text          primary key,
  name        text          not null,
  short       text          not null,
  icon        text          not null default '📦',
  color       text          not null default '#2563eb',
  bg          text          not null default '#eff6ff',
  parent_id   text          references categories(id) on delete cascade,
  created_at  timestamptz   not null default now()
);

-- RLS
alter table categories enable row level security;
drop policy if exists allow_anon_all_categories on categories;
create policy allow_anon_all_categories on categories for all to anon using (true) with check (true);

-- Seed default categories if empty
insert into categories (id, name, short, icon, color, bg, parent_id)
values
  ('MECH','Mechanical Items','Mechanical','⚙️','#2563eb','#eff6ff',null),
  ('ELEC','Electrical Items','Electrical','⚡','#d97706','#fffbeb',null),
  ('INST','Instrumentation Items','Instrumentation','📡','#7c3aed','#f5f3ff',null),
  ('SAFE','Safety Items','Safety','🛡️','#16a34a','#f0fdf4',null),
  ('GEN','General Items','General','📦','#0891b2','#ecfeff',null)
on conflict (id) do nothing;

-- ── Warehouse Groups table ─────────────────────────────────────
create table if not exists warehouse_groups (
  id            uuid          primary key default gen_random_uuid(),
  name          text          not null,
  description   text,
  main_wh_id    uuid          references warehouses(id) on delete set null,
  warehouse_ids uuid[]        not null default '{}',
  created_at    timestamptz   not null default now()
);

-- RLS
alter table warehouse_groups enable row level security;
drop policy if exists allow_anon_all_wh_groups on warehouse_groups;
create policy allow_anon_all_wh_groups on warehouse_groups for all to anon using (true) with check (true);

notify pgrst, 'reload schema';

-- ── Verify ────────────────────────────────────────────────────
select table_name, count(*) as row_count
from (
  select 'categories' as table_name, id from categories
  union all
  select 'warehouse_groups', id::text from warehouse_groups
) t
group by table_name;

-- ================================================================
--  Migration v5b — Fix ALL enum category columns (correct approach)
--  (the old v5 block was removed — it fails because v_stock_levels depends on the column)
-- ================================================================

-- Step 1: Drop views that depend on category column
drop view if exists v_stock_levels cascade;
drop view if exists v_pending_approvals cascade;

-- Step 2: Alter ALL columns that use category_code enum → text
alter table items
  alter column category type text using category::text;

alter table racks
  alter column category type text using category::text;

alter table production_outputs
  alter column category type text using category::text;

-- Step 3: Recreate v_stock_levels view (now uses text category)
create view v_stock_levels as
select
  s.id,
  s.item_id,
  i.code                                      as item_code,
  i.name                                      as item_name,
  i.category,
  i.unit,
  i.cost_price,
  i.min_stock,
  i.is_asset,
  i.asset_code,
  s.warehouse_id,
  w.code                                      as warehouse_code,
  w.name                                      as warehouse_name,
  r.code                                      as rack_code,
  r.name                                      as rack_name,
  s.qty                                       as current_qty,
  round(s.qty * i.cost_price, 2)              as stock_value,
  (s.qty <= i.min_stock)                      as is_low_stock,
  s.updated_at
from      stock      s
join      items      i on i.id = s.item_id
join      warehouses w on w.id = s.warehouse_id
left join racks      r on r.id = i.rack_id;

-- Step 4: Recreate v_pending_approvals if it existed
create view v_pending_approvals as
select 'grn' as type, id, grn_no as voucher_no, warehouse_id, date, status, submitted_by, created_at from purchases where status='Pending Approval'
union all
select 'gin', id, gin_no, warehouse_id, date, status, submitted_by, created_at from gin_vouchers where status='Pending Approval'
union all
select 'transfer', id, trn_no, from_warehouse_id, date, status, submitted_by, created_at from stock_transfers where status='Pending Approval'
union all
select 'con', id, con_no, warehouse_id, date, status, submitted_by, created_at from consumption_vouchers where status='Pending Approval'
union all
select 'pro', id, pro_no, warehouse_id, date, status, submitted_by, created_at from production_orders where status='Pending Approval'
union all
select 'mr', id, mr_no, warehouse_id, date, status, submitted_by, created_at from material_requests where status='Pending Approval'
union all
select 'dmg', id, dmg_no, warehouse_id, date, status, submitted_by, created_at from damaged_products where status='Pending Approval';

notify pgrst, 'reload schema';

-- Verify: all category columns should now be text
select table_name, column_name, data_type
from information_schema.columns
where column_name = 'category'
  and table_name in ('items','racks','production_outputs')
order by table_name;

-- Expected: all show data_type = 'text'
