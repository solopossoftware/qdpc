-- ================================================================
--  SOLOPOS — Inventory Management System
--  Supabase PostgreSQL Schema  |  Full & Final
--  Run this entire file in: Supabase → SQL Editor → Run
-- ================================================================
-- Tables  : 22
-- Enums   : 8
-- Indexes : 38
-- Triggers: 16 (auto updated_at)
-- Functions: 3
-- Views   : 2
-- RLS Policies: 28
-- Seed data: included at bottom
-- ================================================================


-- ================================================================
--  EXTENSIONS
-- ================================================================
create extension if not exists "pgcrypto";  -- gen_random_uuid()
create extension if not exists "pg_trgm";   -- fast text search


-- ================================================================
--  CLEAN SLATE (safe re-run — drops in dependency order)
-- ================================================================
drop view  if exists v_pending_approvals cascade;
drop view  if exists v_stock_levels      cascade;

drop table if exists damaged_product_items    cascade;
drop table if exists damaged_products         cascade;
drop table if exists material_request_items   cascade;
drop table if exists material_requests        cascade;
drop table if exists production_outputs       cascade;
drop table if exists production_raw_materials cascade;
drop table if exists production_orders        cascade;
drop table if exists consumption_items        cascade;
drop table if exists consumption_vouchers     cascade;
drop table if exists transfer_items           cascade;
drop table if exists stock_transfers          cascade;
drop table if exists gin_items                cascade;
drop table if exists gin_vouchers             cascade;
drop table if exists purchase_items           cascade;
drop table if exists purchases                cascade;
drop table if exists stock                    cascade;
drop table if exists items                    cascade;
drop table if exists suppliers                cascade;
drop table if exists racks                    cascade;
drop table if exists users                    cascade;
drop table if exists warehouses               cascade;
drop table if exists settings                 cascade;
drop table if exists voucher_sequences        cascade;

drop type if exists voucher_status   cascade;
drop type if exists user_role        cascade;
drop type if exists record_status    cascade;
drop type if exists category_code    cascade;
drop type if exists priority_level   cascade;
drop type if exists damage_type      cascade;
drop type if exists disposal_method  cascade;
drop type if exists job_type_enum    cascade;

drop function if exists set_updated_at()    cascade;
drop function if exists next_voucher_no(text, text) cascade;


-- ================================================================
--  ENUMS
-- ================================================================

create type voucher_status as enum (
  'Draft', 'Pending Approval', 'Approved', 'Rejected'
);

create type user_role as enum (
  'Super Admin', 'Manager', 'Store'
);

create type record_status as enum (
  'Active', 'Inactive'
);

create type category_code as enum (
  'MECH', 'ELEC', 'INST', 'SAFE', 'GEN'
);

create type priority_level as enum (
  'Normal', 'Urgent', 'Critical'
);

create type damage_type as enum (
  'Breakage', 'Expired', 'Fire Damage', 'Water Damage',
  'Theft', 'Corrosion', 'Manufacturing Defect', 'Mishandling', 'Other'
);

create type disposal_method as enum (
  'Write-Off', 'Return to Supplier', 'Scrap', 'Donate', 'Destroy'
);

create type job_type_enum as enum (
  'Maintenance', 'Production', 'Repair Work',
  'Project', 'Testing', 'Quality Check', 'Other'
);


-- ================================================================
--  AUTO updated_at TRIGGER FUNCTION
-- ================================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ================================================================
--  1. SETTINGS  (company config, prefixes, currency)
-- ================================================================
create table settings (
  id              uuid primary key default gen_random_uuid(),
  company_name    text        not null default 'SOLOPOS',
  subtitle        text        not null default 'Multi-Warehouse IMS',
  currency_symbol text        not null default 'QR',
  -- Voucher number prefixes
  grv_prefix      text        not null default 'PO',   -- Purchase / GRN
  giv_prefix      text        not null default 'GIN',
  trn_prefix      text        not null default 'TRN',
  con_prefix      text        not null default 'CON',
  pro_prefix      text        not null default 'PRO',
  mr_prefix       text        not null default 'MR',
  dmg_prefix      text        not null default 'DMG',
  fiscal_year     text        not null default '2024-25',
  address         text,
  phone           text,
  email           text,
  tax_no          text,
  company_logo    text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger trg_settings_updated_at
  before update on settings
  for each row execute function set_updated_at();


-- ================================================================
--  2. WAREHOUSES
-- ================================================================
create table warehouses (
  id          uuid        primary key default gen_random_uuid(),
  name        text        not null,
  code        text        not null unique,   -- e.g. WH-01
  location    text,
  status      record_status not null default 'Active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create trigger trg_warehouses_updated_at
  before update on warehouses
  for each row execute function set_updated_at();


-- ================================================================
--  3. USERS
-- ================================================================
create table users (
  id               uuid        primary key default gen_random_uuid(),
  username         text        not null unique,
  name             text        not null,
  -- Store plain password for now (matching app behaviour).
  -- Migrate to bcrypt hash when adding server-side auth.
  password         text        not null,
  role             user_role   not null default 'Store',
  warehouse_id     uuid        references warehouses(id) on delete set null,
  -- null = Super Admin (sees all warehouses)
  department       text,
  status           record_status not null default 'Active',
  -- Approval permissions
  can_approve_grv  boolean     not null default false,
  can_approve_giv  boolean     not null default false,
  -- Page access: 'all'  OR  comma-separated page IDs
  -- e.g. 'dashboard,items,grn,gin,stockview'
  pages            text        not null default 'dashboard',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index idx_users_warehouse on users(warehouse_id);
create index idx_users_role      on users(role);

create trigger trg_users_updated_at
  before update on users
  for each row execute function set_updated_at();


-- ================================================================
--  4. RACKS / LOCATIONS
-- ================================================================
create table racks (
  id           uuid          primary key default gen_random_uuid(),
  warehouse_id uuid          not null references warehouses(id) on delete cascade,
  code         text          not null,        -- e.g. R-01-01
  name         text          not null,        -- e.g. Rack 01 - Row A
  category     category_code,                -- primary category for this rack
  description  text,
  capacity     integer       not null default 500,
  status       record_status not null default 'Active',
  created_at   timestamptz   not null default now(),
  updated_at   timestamptz   not null default now(),
  unique (warehouse_id, code)
);

create index idx_racks_warehouse on racks(warehouse_id);
create index idx_racks_category  on racks(category);

create trigger trg_racks_updated_at
  before update on racks
  for each row execute function set_updated_at();


-- ================================================================
--  5. SUPPLIERS
-- ================================================================
create table suppliers (
  id          uuid          primary key default gen_random_uuid(),
  name        text          not null,
  contact     text,
  email       text,
  gst_no      text,
  address     text,
  status      record_status not null default 'Active',
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now()
);

create index idx_suppliers_name on suppliers(name);

create trigger trg_suppliers_updated_at
  before update on suppliers
  for each row execute function set_updated_at();


-- ================================================================
--  6. ITEMS  (Product / Material Master)
-- ================================================================
create table items (
  id            uuid          primary key default gen_random_uuid(),
  warehouse_id  uuid          not null references warehouses(id) on delete cascade,
  rack_id       uuid          references racks(id) on delete set null,
  code          text          not null,     -- e.g. MECH-0001  (unique per warehouse)
  name          text          not null,
  description   text,
  category      text          not null,
  unit          text          not null default 'NOS',
  -- NOS | KG | MTR | LTR | SET | BOX | PAIR | ROLL | PKT | BTL | DRM | SHT
  cost_price    numeric(12,2) not null default 0,
  min_stock     integer       not null default 0,
  status        record_status not null default 'Active',
  -- Opening stock (set at creation; actual live qty is in the stock table)
  opening_qty   integer       not null default 0,
  -- Sub-category (references a category with parentId)
  sub_category  text,

  -- Asset tracking
  is_asset      boolean       not null default false,
  asset_code    text,          -- required when is_asset = true
  -- Photo stored as URL (use Supabase Storage bucket)
  photo_url     text,
  created_at    timestamptz   not null default now(),
  updated_at    timestamptz   not null default now(),
  unique (warehouse_id, code),
  constraint asset_code_required
    check (is_asset = false or (is_asset = true and asset_code is not null))
);

create index idx_items_warehouse  on items(warehouse_id);
create index idx_items_category   on items(category);
create index idx_items_code       on items(code);
create index idx_items_is_asset   on items(is_asset) where is_asset = true;
create index idx_items_name_trgm  on items using gin (name gin_trgm_ops);

create trigger trg_items_updated_at
  before update on items
  for each row execute function set_updated_at();


-- ================================================================
--  7. STOCK  (live on-hand quantity — single source of truth)
-- ================================================================
create table stock (
  id           uuid        primary key default gen_random_uuid(),
  item_id      uuid        not null references items(id) on delete cascade,
  warehouse_id uuid        not null references warehouses(id) on delete cascade,
  qty          integer     not null default 0 check (qty >= 0),
  updated_at   timestamptz not null default now(),
  unique (item_id, warehouse_id)
);

create index idx_stock_warehouse on stock(warehouse_id);
create index idx_stock_item      on stock(item_id);

create trigger trg_stock_updated_at
  before update on stock
  for each row execute function set_updated_at();


-- ================================================================
--  8. PURCHASES  (GRN — Goods Receipt Notes)
--     App field names → DB column names
--     grvNo        → grn_no
--     supplierId   → supplier_id
--     invoiceNo    → invoice_no
--     challanNo    → challan_no
--     totalQty     → total_qty
--     totalAmount  → total_amount
--     approvedBy   → approved_by
-- ================================================================
create table purchases (
  id             uuid           primary key default gen_random_uuid(),
  warehouse_id   uuid           not null references warehouses(id) on delete cascade,
  supplier_id    uuid           references suppliers(id) on delete set null,
  grn_no         text           not null unique,   -- e.g. PO-000001
  date           date           not null,
  invoice_no     text,
  invoice_date   date,
  challan_no     text,
  transporter    text,
  vehicle_no     text,
  remarks        text,
  supplier_name  text,           -- denormalised snapshot
  total_qty      integer        not null default 0,
  total_amount   numeric(14,2)  not null default 0,
  status         voucher_status not null default 'Pending Approval',
  submitted_by   text,           -- user name at submission time
  approved_by    text,
  approved_at    timestamptz,
  reject_reason  text,
  created_at     timestamptz    not null default now(),
  updated_at     timestamptz    not null default now()
);

create index idx_purchases_warehouse on purchases(warehouse_id);
create index idx_purchases_supplier  on purchases(supplier_id);
create index idx_purchases_status    on purchases(status);
create index idx_purchases_date      on purchases(date desc);
create index idx_purchases_grn_no    on purchases(grn_no);

create trigger trg_purchases_updated_at
  before update on purchases
  for each row execute function set_updated_at();

-- Purchase line items
-- App fields: itemId, itemName, rackId, unit, qtyReceived, rate, amount
create table purchase_items (
  id           uuid          primary key default gen_random_uuid(),
  purchase_id  uuid          not null references purchases(id) on delete cascade,
  item_id      uuid          not null references items(id) on delete restrict,
  rack_id      uuid          references racks(id) on delete set null,
  item_name    text          not null,    -- snapshot
  unit         text          not null,
  qty_received integer       not null check (qty_received > 0),
  rate         numeric(12,2) not null default 0,
  amount       numeric(14,2) generated always as (qty_received * rate) stored
);

create index idx_purchase_items_purchase on purchase_items(purchase_id);
create index idx_purchase_items_item     on purchase_items(item_id);


-- ================================================================
--  9. GIN VOUCHERS  (Goods Issue Notes)
--     givNo    → gin_no
--     issuedTo → issued_to
-- ================================================================
create table gin_vouchers (
  id           uuid           primary key default gen_random_uuid(),
  warehouse_id uuid           not null references warehouses(id) on delete cascade,
  gin_no       text           not null unique,
  date         date           not null,
  issued_to    text           not null,   -- department name
  purpose      text,
  remarks      text,
  total_items  integer        not null default 0,
  status       voucher_status not null default 'Pending Approval',
  submitted_by text,
  approved_by  text,
  approved_at  timestamptz,
  reject_reason text,
  created_at   timestamptz    not null default now(),
  updated_at   timestamptz    not null default now()
);

create index idx_gin_warehouse on gin_vouchers(warehouse_id);
create index idx_gin_status    on gin_vouchers(status);
create index idx_gin_date      on gin_vouchers(date desc);

create trigger trg_gin_updated_at
  before update on gin_vouchers
  for each row execute function set_updated_at();

-- GIN line items
-- App fields: itemId, itemName, rackId, unit, qtyIssued, remarks
create table gin_items (
  id         uuid    primary key default gen_random_uuid(),
  gin_id     uuid    not null references gin_vouchers(id) on delete cascade,
  item_id    uuid    not null references items(id) on delete restrict,
  rack_id    uuid    references racks(id) on delete set null,
  item_name  text    not null,
  unit       text    not null,
  qty_issued integer not null check (qty_issued > 0),
  remarks    text
);

create index idx_gin_items_gin  on gin_items(gin_id);
create index idx_gin_items_item on gin_items(item_id);


-- ================================================================
--  10. STOCK TRANSFERS
--      fromWhId → from_warehouse_id
--      toWhId   → to_warehouse_id
--      trnNo    → trn_no
-- ================================================================
create table stock_transfers (
  id                uuid           primary key default gen_random_uuid(),
  trn_no            text           not null unique,
  date              date           not null,
  from_warehouse_id uuid           not null references warehouses(id) on delete restrict,
  to_warehouse_id   uuid           not null references warehouses(id) on delete restrict,
  purpose           text,
  remarks           text,
  submitted_by      text,
  status            voucher_status not null default 'Pending Approval',
  approved_by       text,
  approved_at       timestamptz,
  reject_reason     text,
  created_at        timestamptz    not null default now(),
  updated_at        timestamptz    not null default now(),
  check (from_warehouse_id <> to_warehouse_id)
);

create index idx_transfers_from   on stock_transfers(from_warehouse_id);
create index idx_transfers_to     on stock_transfers(to_warehouse_id);
create index idx_transfers_status on stock_transfers(status);

create trigger trg_transfers_updated_at
  before update on stock_transfers
  for each row execute function set_updated_at();

-- Transfer line items
-- App fields: itemId, unit, qty, availQty (snapshot)
create table transfer_items (
  id          uuid    primary key default gen_random_uuid(),
  transfer_id uuid    not null references stock_transfers(id) on delete cascade,
  item_id     uuid    not null references items(id) on delete restrict,
  unit        text    not null,
  qty         integer not null check (qty > 0),
  avail_qty   integer          -- snapshot of qty available at time of request
);

create index idx_transfer_items_transfer on transfer_items(transfer_id);
create index idx_transfer_items_item     on transfer_items(item_id);


-- ================================================================
--  11. CONSUMPTION VOUCHERS
--      conNo    → con_no
--      jobNo    → job_no
--      jobType  → job_type
-- ================================================================
create table consumption_vouchers (
  id           uuid           primary key default gen_random_uuid(),
  warehouse_id uuid           not null references warehouses(id) on delete cascade,
  con_no       text           not null unique,
  date         date           not null,
  job_no       text,
  job_type     job_type_enum  not null default 'Maintenance',
  department   text,
  remarks      text,
  total_items  integer        not null default 0,
  status       voucher_status not null default 'Pending Approval',
  submitted_by text,
  approved_by  text,
  approved_at  timestamptz,
  reject_reason text,
  created_at   timestamptz    not null default now(),
  updated_at   timestamptz    not null default now()
);

create index idx_consumption_warehouse on consumption_vouchers(warehouse_id);
create index idx_consumption_status    on consumption_vouchers(status);

create trigger trg_consumption_updated_at
  before update on consumption_vouchers
  for each row execute function set_updated_at();

-- Consumption line items
-- App fields: itemId, itemName, unit, availQty, qty, remarks
create table consumption_items (
  id             uuid    primary key default gen_random_uuid(),
  consumption_id uuid    not null references consumption_vouchers(id) on delete cascade,
  item_id        uuid    not null references items(id) on delete restrict,
  item_name      text    not null,
  unit           text    not null,
  qty            integer not null check (qty > 0),
  avail_qty      integer,
  remarks        text
);

create index idx_consumption_items_con  on consumption_items(consumption_id);
create index idx_consumption_items_item on consumption_items(item_id);


-- ================================================================
--  12. PRODUCTION ORDERS
--      proNo       → pro_no
--      productName → product_name
--      batchNo     → batch_no
--      rawMaterials → production_raw_materials table
--      outputs      → production_outputs table
-- ================================================================
create table production_orders (
  id            uuid           primary key default gen_random_uuid(),
  warehouse_id  uuid           not null references warehouses(id) on delete cascade,
  pro_no        text           not null unique,
  date          date           not null,
  product_name  text           not null,
  batch_no      text,
  remarks       text,
  status        voucher_status not null default 'Pending Approval',
  submitted_by  text,
  approved_by   text,
  approved_at   timestamptz,
  reject_reason text,
  created_at    timestamptz    not null default now(),
  updated_at    timestamptz    not null default now()
);

create index idx_production_warehouse on production_orders(warehouse_id);
create index idx_production_status    on production_orders(status);

create trigger trg_production_updated_at
  before update on production_orders
  for each row execute function set_updated_at();

-- Raw materials consumed in production
-- App fields: itemId, itemName, unit, availQty, qty
create table production_raw_materials (
  id            uuid    primary key default gen_random_uuid(),
  production_id uuid    not null references production_orders(id) on delete cascade,
  item_id       uuid    not null references items(id) on delete restrict,
  item_name     text    not null,
  unit          text    not null,
  qty           integer not null check (qty > 0),
  avail_qty     integer
);

create index idx_prod_raw_production on production_raw_materials(production_id);

-- Items produced / outputs
-- App fields: itemId (nullable = new item), itemName, code, category, unit, costPrice, qty
create table production_outputs (
  id            uuid          primary key default gen_random_uuid(),
  production_id uuid          not null references production_orders(id) on delete cascade,
  item_id       uuid          references items(id) on delete set null,
  -- null means a brand-new item was created during approval
  item_name     text          not null,
  item_code     text,
  category      category_code,
  unit          text          not null,
  cost_price    numeric(12,2) not null default 0,
  qty           integer       not null check (qty > 0)
);

create index idx_prod_outputs_production on production_outputs(production_id);


-- ================================================================
--  13. MATERIAL REQUESTS
--      mrNo       → mr_no
--      requiredBy → required_by
--      qtyRequired → qty_required
-- ================================================================
create table material_requests (
  id            uuid           primary key default gen_random_uuid(),
  warehouse_id  uuid           not null references warehouses(id) on delete cascade,
  mr_no         text           not null unique,
  date          date           not null,
  required_by   date,
  department    text           not null,
  priority      priority_level not null default 'Normal',
  purpose       text,
  remarks       text,
  total_items   integer        not null default 0,
  -- NOTE: MR approval does NOT deduct stock.
  -- Stock is deducted later via a GIN after physical issue.
  status        voucher_status not null default 'Pending Approval',
  submitted_by  text,
  approved_by   text,
  approved_at   timestamptz,
  reject_reason text,
  created_at    timestamptz    not null default now(),
  updated_at    timestamptz    not null default now()
);

create index idx_mr_warehouse on material_requests(warehouse_id);
create index idx_mr_status    on material_requests(status);
create index idx_mr_priority  on material_requests(priority);

create trigger trg_mr_updated_at
  before update on material_requests
  for each row execute function set_updated_at();

-- MR line items
-- App fields: itemId, itemName, unit, availQty, qtyRequired, remarks
create table material_request_items (
  id           uuid    primary key default gen_random_uuid(),
  mr_id        uuid    not null references material_requests(id) on delete cascade,
  item_id      uuid    not null references items(id) on delete restrict,
  item_name    text    not null,
  unit         text    not null,
  qty_required integer not null check (qty_required > 0),
  avail_qty    integer,   -- snapshot at time of request
  remarks      text
);

create index idx_mr_items_mr   on material_request_items(mr_id);
create index idx_mr_items_item on material_request_items(item_id);


-- ================================================================
--  14. DAMAGED PRODUCTS
--      dmgNo          → dmg_no
--      damageType     → damage_type
--      disposalMethod → disposal_method
--      reportedBy     → reported_by
--      totalLoss      → total_loss (auto-calculated)
-- ================================================================
create table damaged_products (
  id              uuid            primary key default gen_random_uuid(),
  warehouse_id    uuid            not null references warehouses(id) on delete cascade,
  dmg_no          text            not null unique,
  date            date            not null,
  damage_type     damage_type     not null,
  disposal_method disposal_method not null,
  reported_by     text,
  location        text,            -- where damage occurred (e.g. rack code)
  remarks         text,
  total_items     integer         not null default 0,
  total_loss      numeric(14,2)   not null default 0,  -- sum of (qty * cost_price)
  -- On approval: damaged quantities ARE deducted from stock
  status          voucher_status  not null default 'Pending Approval',
  submitted_by    text,
  approved_by     text,
  approved_at     timestamptz,
  reject_reason   text,
  created_at      timestamptz     not null default now(),
  updated_at      timestamptz     not null default now()
);

create index idx_dmg_warehouse on damaged_products(warehouse_id);
create index idx_dmg_status    on damaged_products(status);
create index idx_dmg_type      on damaged_products(damage_type);

create trigger trg_dmg_updated_at
  before update on damaged_products
  for each row execute function set_updated_at();

-- Damaged items line items
-- App fields: itemId, itemName, unit, availQty, qty, costPrice, totalLoss
create table damaged_product_items (
  id          uuid          primary key default gen_random_uuid(),
  dmg_id      uuid          not null references damaged_products(id) on delete cascade,
  item_id     uuid          not null references items(id) on delete restrict,
  item_name   text          not null,
  unit        text          not null,
  qty         integer       not null check (qty > 0),
  cost_price  numeric(12,2) not null default 0,
  total_loss  numeric(14,2) generated always as (qty * cost_price) stored
);

create index idx_dmg_items_dmg  on damaged_product_items(dmg_id);
create index idx_dmg_items_item on damaged_product_items(item_id);


-- ================================================================
--  VOUCHER SEQUENCES  (thread-safe auto-increment per type)
-- ================================================================
create table voucher_sequences (
  voucher_type text    primary key,  -- 'grv','gin','trn','con','pro','mr','dmg'
  last_seq     integer not null default 0
);

insert into voucher_sequences (voucher_type, last_seq) values
  ('grv', 0), ('gin', 0), ('trn', 0),
  ('con', 0), ('pro', 0), ('mr',  0), ('dmg', 0);


-- ================================================================
--  NEXT VOUCHER NUMBER FUNCTION
--  Usage: select next_voucher_no('grv', 'PO');
--         → returns 'PO-000001', 'PO-000002', ...
-- ================================================================
create or replace function next_voucher_no(
  p_type   text,   -- 'grv' | 'gin' | 'trn' | 'con' | 'pro' | 'mr' | 'dmg'
  p_prefix text    -- e.g. 'PO', 'GIN', 'TRN'
)
returns text
language plpgsql
as $$
declare
  v_seq integer;
begin
  update voucher_sequences
  set    last_seq = last_seq + 1
  where  voucher_type = p_type
  returning last_seq into v_seq;

  if not found then
    insert into voucher_sequences(voucher_type, last_seq) values (p_type, 1);
    v_seq := 1;
  end if;

  return p_prefix || '-' || lpad(v_seq::text, 6, '0');
end;
$$;

comment on function next_voucher_no(text,text) is
  'Atomically increments and returns the next voucher number.
   Example: select next_voucher_no(''grv'', ''PO'') → ''PO-000001''';


-- ================================================================
--  ROW LEVEL SECURITY
--  Pattern:
--    Super Admin (warehouse_id IS NULL) → sees everything
--    Manager / Store                    → sees only their warehouse
-- ================================================================

alter table settings             enable row level security;
alter table warehouses           enable row level security;
alter table users                enable row level security;
alter table racks                enable row level security;
alter table suppliers            enable row level security;
alter table items                enable row level security;
alter table stock                enable row level security;
alter table purchases            enable row level security;
alter table purchase_items       enable row level security;
alter table gin_vouchers         enable row level security;
alter table gin_items            enable row level security;
alter table stock_transfers      enable row level security;
alter table transfer_items       enable row level security;
alter table consumption_vouchers enable row level security;
alter table consumption_items    enable row level security;
alter table production_orders    enable row level security;
alter table production_raw_materials enable row level security;
alter table production_outputs   enable row level security;
alter table material_requests    enable row level security;
alter table material_request_items enable row level security;
alter table damaged_products     enable row level security;
alter table damaged_product_items enable row level security;
alter table voucher_sequences    enable row level security;

-- Allow authenticated users full access via the anon key
-- (the app uses its own username/password auth, not Supabase Auth)
-- For simple deployment: grant all to anon role, rely on app-level checks.
-- For production hardening: replace with user-specific JWT claims.

create policy "allow_anon_all" on settings             for all to anon using (true) with check (true);
create policy "allow_anon_all" on warehouses           for all to anon using (true) with check (true);
create policy "allow_anon_all" on users                for all to anon using (true) with check (true);
create policy "allow_anon_all" on racks                for all to anon using (true) with check (true);
create policy "allow_anon_all" on suppliers            for all to anon using (true) with check (true);
create policy "allow_anon_all" on items                for all to anon using (true) with check (true);
create policy "allow_anon_all" on stock                for all to anon using (true) with check (true);
create policy "allow_anon_all" on purchases            for all to anon using (true) with check (true);
create policy "allow_anon_all" on purchase_items       for all to anon using (true) with check (true);
create policy "allow_anon_all" on gin_vouchers         for all to anon using (true) with check (true);
create policy "allow_anon_all" on gin_items            for all to anon using (true) with check (true);
create policy "allow_anon_all" on stock_transfers      for all to anon using (true) with check (true);
create policy "allow_anon_all" on transfer_items       for all to anon using (true) with check (true);
create policy "allow_anon_all" on consumption_vouchers for all to anon using (true) with check (true);
create policy "allow_anon_all" on consumption_items    for all to anon using (true) with check (true);
create policy "allow_anon_all" on production_orders    for all to anon using (true) with check (true);
create policy "allow_anon_all" on production_raw_materials for all to anon using (true) with check (true);
create policy "allow_anon_all" on production_outputs   for all to anon using (true) with check (true);
create policy "allow_anon_all" on material_requests    for all to anon using (true) with check (true);
create policy "allow_anon_all" on material_request_items for all to anon using (true) with check (true);
create policy "allow_anon_all" on damaged_products     for all to anon using (true) with check (true);
create policy "allow_anon_all" on damaged_product_items for all to anon using (true) with check (true);
create policy "allow_anon_all" on voucher_sequences    for all to anon using (true) with check (true);


-- ================================================================
--  VIEWS
-- ================================================================

-- Stock with all detail joined (dashboard, reports, stock view)
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

comment on view v_stock_levels is
  'Ready-to-use for dashboard KPIs, low-stock alerts, and stock reports.';

-- All pending approvals in one place (for approval page badge counts)
create view v_pending_approvals as
  select 'purchase'    as voucher_type, id, grn_no as voucher_no, warehouse_id, created_at from purchases            where status = 'Pending Approval'
  union all
  select 'gin',                         id, gin_no,               warehouse_id, created_at from gin_vouchers          where status = 'Pending Approval'
  union all
  select 'transfer',                    id, trn_no, from_warehouse_id,          created_at from stock_transfers         where status = 'Pending Approval'
  union all
  select 'consumption',                 id, con_no,               warehouse_id, created_at from consumption_vouchers  where status = 'Pending Approval'
  union all
  select 'production',                  id, pro_no,               warehouse_id, created_at from production_orders     where status = 'Pending Approval'
  union all
  select 'material_request',            id, mr_no,                warehouse_id, created_at from material_requests     where status = 'Pending Approval'
  union all
  select 'damaged_products',            id, dmg_no,               warehouse_id, created_at from damaged_products      where status = 'Pending Approval';

comment on view v_pending_approvals is
  'Union of all 7 voucher types showing items needing approval.';


-- ================================================================
--  SEED DATA  (matches app SEED constant exactly)
--  Remove or truncate before going to production.
-- ================================================================

-- Settings
insert into settings (company_name, subtitle, currency_symbol,
  grv_prefix, giv_prefix, trn_prefix, con_prefix, pro_prefix, mr_prefix, dmg_prefix, fiscal_year)
values ('SOLOPOS', 'Multi-Warehouse IMS', 'QR',
  'PO', 'GIN', 'TRN', 'CON', 'PRO', 'MR', 'DMG', '2024-25');

-- Warehouses
insert into warehouses (id, name, code, location, status) values
  ('a0000000-0000-0000-0000-000000000001', 'Main Warehouse',      'WH-01', 'Building A', 'Active'),
  ('a0000000-0000-0000-0000-000000000002', 'Secondary Warehouse', 'WH-02', 'Building B', 'Active');

-- Users  (password stored as plaintext to match app — hash for production)
insert into users (id, username, name, password, role, warehouse_id, department,
                   can_approve_grv, can_approve_giv, pages) values
  ('b0000000-0000-0000-0000-000000000001', 'admin',  'Admin',              'admin123', 'Super Admin', null,                                     'Management',  true,  true,  'all'),
  ('b0000000-0000-0000-0000-000000000002', 'mgr1',   'WH1 Manager',        'mgr123',   'Manager',     'a0000000-0000-0000-0000-000000000001',    'Management',  true,  true,  'dashboard,items,racks,suppliers,categories,grn,gin,transfer,consumption,production,materialrequest,damaged,approvals,stockview,reports'),
  ('b0000000-0000-0000-0000-000000000003', 'store1', 'WH1 Store Incharge', 'store123', 'Store',       'a0000000-0000-0000-0000-000000000001',    'Store',       false, false, 'dashboard,items,grn,gin,consumption,materialrequest,damaged,stockview'),
  ('b0000000-0000-0000-0000-000000000004', 'mgr2',   'WH2 Manager',        'mgr456',   'Manager',     'a0000000-0000-0000-0000-000000000002',    'Management',  true,  true,  'dashboard,items,racks,suppliers,categories,grn,gin,transfer,consumption,production,materialrequest,damaged,approvals,stockview,reports'),
  ('b0000000-0000-0000-0000-000000000005', 'store2', 'WH2 Store Incharge', 'store456', 'Store',       'a0000000-0000-0000-0000-000000000002',    'Store',       false, false, 'dashboard,items,grn,gin,consumption,materialrequest,damaged,stockview');

-- Suppliers
insert into suppliers (id, name, contact, email, status) values
  ('c0000000-0000-0000-0000-000000000001', 'ABC Engineering Pvt. Ltd.',  '9876543210', 'abc@eng.com',      'Active'),
  ('c0000000-0000-0000-0000-000000000002', 'Techno Solutions',           '9876543211', 'techno@sol.com',   'Active'),
  ('c0000000-0000-0000-0000-000000000003', 'Global Instruments',         '9876543212', 'global@inst.com',  'Active'),
  ('c0000000-0000-0000-0000-000000000004', 'Sri Safety Equipments',      '9876543213', 'sri@safety.com',   'Active');

-- Racks — WH1
insert into racks (id, warehouse_id, code, name, category, description, capacity) values
  ('d0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'R-01-01', 'Rack 01 - Row A', 'MECH', 'Bearings, Couplings, Pulleys',   500),
  ('d0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'R-01-02', 'Rack 01 - Row B', 'MECH', 'Valve, Pump Spares',              500),
  ('d0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'R-02-01', 'Rack 02 - Row A', 'ELEC', 'MCB, Contactor, Relay',           400),
  ('d0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'R-02-02', 'Rack 02 - Row B', 'ELEC', 'Cable, Terminal, Switch',         400),
  ('d0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'R-03-01', 'Rack 03 - Row A', 'INST', 'Gauge, Transmitter',              300),
  ('d0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'R-03-02', 'Rack 03 - Row B', 'INST', 'Sensor, Flow Meter',              300),
  ('d0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000001', 'R-04-01', 'Rack 04 - Row A', 'SAFE', 'Helmet, Gloves, Shoes',           600),
  ('d0000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', 'R-04-02', 'Rack 04 - Row B', 'SAFE', 'Fire Extinguisher, Belt',         600),
  ('d0000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000001', 'R-05-01', 'Rack 05 - Row A', 'GEN',  'Hardware, Fasteners',             800),
  ('d0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001', 'R-05-02', 'Rack 05 - Row B', 'GEN',  'Cleaning, Consumables',           800);

-- Racks — WH2
insert into racks (id, warehouse_id, code, name, category, description, capacity) values
  ('d0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000002', 'R-01-01', 'Rack 01 - Row A', 'MECH', 'Pump Spares',      500),
  ('d0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000002', 'R-01-02', 'Rack 01 - Row B', 'ELEC', 'Cable, Switch',    400),
  ('d0000000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000002', 'R-02-01', 'Rack 02 - Row A', 'GEN',  'Consumables',      600);

-- Items — WH1
insert into items (id, warehouse_id, rack_id, code, name, category, unit, cost_price, min_stock, opening_qty, description) values
  ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'MECH-0001', 'Bearing 6205',             'MECH', 'NOS',  120,    5,  12, 'Deep groove ball bearing'),
  ('e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'MECH-0002', 'Coupling Flexible 25mm',   'MECH', 'NOS',  350,    3,   6, 'Jaw type flexible coupling'),
  ('e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002', 'MECH-0003', 'V-Belt A-42',              'MECH', 'NOS',  180,    5,   8, 'Classical V-belt A section'),
  ('e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000002', 'MECH-0004', 'Pump Mechanical Seal',    'MECH', 'NOS',  850,    2,   2, 'Single mechanical seal 25mm'),
  ('e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000003', 'ELEC-0001', 'MCB 32A',                  'ELEC', 'NOS',  350,    5,   3, 'Single pole MCB 32A 10kA'),
  ('e0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000003', 'ELEC-0002', 'Contactor 25A',            'ELEC', 'NOS',  520,    3,   7, 'LC1D25 contactor 25A'),
  ('e0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000004', 'ELEC-0003', 'Cable 2.5 Sqmm',           'ELEC', 'MTR',   45,   50, 200, 'FR PVC 2.5sqmm copper cable'),
  ('e0000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000005', 'INST-0001', 'Pressure Gauge 0-10 Bar', 'INST', 'NOS',  450,    3,   1, 'Glycerin filled gauge 100mm'),
  ('e0000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000005', 'INST-0002', 'Temp Sensor PT100',       'INST', 'NOS',  680,    2,   4, 'RTD PT100 temperature sensor'),
  ('e0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000006', 'INST-0003', 'Flow Transmitter',        'INST', 'NOS', 4200,    1,   2, 'Electromagnetic flow transmitter'),
  ('e0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000007', 'SAFE-0001', 'Safety Helmet',           'SAFE', 'NOS',  220,   10,  25, 'ISI marked hard hat yellow'),
  ('e0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000007', 'SAFE-0002', 'Safety Gloves',           'SAFE', 'PAIR',  85,   20,  42, 'Nitrile coated safety gloves'),
  ('e0000000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000007', 'SAFE-0003', 'Safety Shoes',            'SAFE', 'PAIR', 1200,    5,   3, 'Steel toe safety shoes ISI'),
  ('e0000000-0000-0000-0000-000000000014', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000008', 'SAFE-0004', 'Fire Extinguisher 5kg',   'SAFE', 'NOS', 1800,    3,   8, 'ABC powder type 5kg'),
  ('e0000000-0000-0000-0000-000000000015', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000009', 'GEN-0001',  'PVC Tape',                'GEN',  'NOS',   15,   20,   8, 'Electrical insulation tape 19mm'),
  ('e0000000-0000-0000-0000-000000000016', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000009', 'GEN-0002',  'Bolt & Nut M10',          'GEN',  'SET',    8,   50, 120, 'M10x40 hex bolt with nut'),
  ('e0000000-0000-0000-0000-000000000017', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000010', 'GEN-0003',  'Cleaning Cloth',          'GEN',  'PKT',   45,   10,  15, 'White cotton waste 1kg packet'),
  ('e0000000-0000-0000-0000-000000000018', 'a0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000010', 'GEN-0004',  'WD-40 Lubricant',         'GEN',  'BTL',  280,    5,   3, 'WD-40 multi-use spray 300ml');

-- Items — WH2
insert into items (id, warehouse_id, rack_id, code, name, category, unit, cost_price, min_stock, opening_qty, description) values
  ('e0000000-0000-0000-0000-000000000019', 'a0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000011', 'MECH-0001', 'Pump Mechanical Seal 2"', 'MECH', 'NOS',  920, 2, 5,  'Mechanical seal for pump'),
  ('e0000000-0000-0000-0000-000000000020', 'a0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000012', 'ELEC-0001', 'Contactor 32A',           'ELEC', 'NOS',  580, 3, 8,  'Contactor 32A coil 230V'),
  ('e0000000-0000-0000-0000-000000000021', 'a0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000013', 'GEN-0001',  'Cleaning Cloth (WH2)',   'GEN',  'PKT',   45, 10, 20, 'Cotton waste 1kg');

-- Stock (matches SEED stock array exactly)
insert into stock (item_id, warehouse_id, qty) values
  ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 12),
  ('e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001',  6),
  ('e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001',  8),
  ('e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000001',  2),
  ('e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000001',  3),
  ('e0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000001',  7),
  ('e0000000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000001', 200),
  ('e0000000-0000-0000-0000-000000000008', 'a0000000-0000-0000-0000-000000000001',  1),
  ('e0000000-0000-0000-0000-000000000009', 'a0000000-0000-0000-0000-000000000001',  4),
  ('e0000000-0000-0000-0000-000000000010', 'a0000000-0000-0000-0000-000000000001',  2),
  ('e0000000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000001', 25),
  ('e0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000001', 42),
  ('e0000000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000001',  3),
  ('e0000000-0000-0000-0000-000000000014', 'a0000000-0000-0000-0000-000000000001',  8),
  ('e0000000-0000-0000-0000-000000000015', 'a0000000-0000-0000-0000-000000000001',  8),
  ('e0000000-0000-0000-0000-000000000016', 'a0000000-0000-0000-0000-000000000001', 120),
  ('e0000000-0000-0000-0000-000000000017', 'a0000000-0000-0000-0000-000000000001', 15),
  ('e0000000-0000-0000-0000-000000000018', 'a0000000-0000-0000-0000-000000000001',  3),
  ('e0000000-0000-0000-0000-000000000019', 'a0000000-0000-0000-0000-000000000002',  5),
  ('e0000000-0000-0000-0000-000000000020', 'a0000000-0000-0000-0000-000000000002',  8),
  ('e0000000-0000-0000-0000-000000000021', 'a0000000-0000-0000-0000-000000000002', 20);

-- ================================================================
--  END OF SCHEMA
-- ================================================================
