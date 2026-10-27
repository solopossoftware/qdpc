-- ================================================================
--  SOLOPOS — PRODUCTION APP  (completely separate from STORE)
--  Run ONCE in Supabase → SQL Editor. Safe to re-run.
--
--  ISOLATION RULES THIS FILE FOLLOWS
--   * Every object here is prefixed  prod_  /  _p_
--   * NO foreign key points from a prod_ table to a Store table, or back.
--   * NO function here reads or writes a Store table
--     (items, stock, warehouses, users, categories, purchases, gin_*, ...).
--   * Production has its OWN users, categories, items, locations, stock,
--     tanks, fills, runs, ledger, audit log, settings and number counters.
--   * A Store item and a Production item with the same name are two
--     unrelated records.  Nothing is synchronised.
--
--  The Store tables are not touched, renamed or migrated.
--  Quantities in the Production domain are numeric(14,3) (decimals OK).
-- ================================================================
create extension if not exists pgcrypto;

-- ────────────────────────────────────────────────────────────────
--  1. USERS (own login — passwords are stored hashed)
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_users (
  id            uuid        primary key default gen_random_uuid(),
  username      text        not null unique,
  name          text        not null,
  password_hash text        not null,
  role          text        not null default 'Operator' check (role in ('Super Admin','Manager','Operator')),
  status        text        not null default 'Active'   check (status in ('Active','Inactive')),
  pages         text        not null default 'dashboard',
  can_approve   boolean     not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ────────────────────────────────────────────────────────────────
--  2. MASTERS: categories, items, locations
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_categories (
  id         text        primary key,
  name       text        not null,
  color      text        not null default '#2563eb',
  is_final   boolean     not null default false,       -- counted as "final product" on the dashboard
  sort_order integer     not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists prod_items (
  id          uuid          primary key default gen_random_uuid(),
  code        text          not null unique,
  name        text          not null,
  category_id text          references prod_categories(id) on delete set null,
  unit        text          not null default 'MT',
  capacity    numeric(14,3) not null default 0 check (capacity >= 0),   -- for the % bar (non-tank stock)
  min_stock   numeric(14,3) not null default 0 check (min_stock >= 0),
  description text,
  status      text          not null default 'Active' check (status in ('Active','Inactive')),
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now()
);
create index if not exists idx_prod_items_cat on prod_items(category_id);

create table if not exists prod_locations (        -- production units / yards (NSF Unit, Packing Area, ...)
  id          uuid        primary key default gen_random_uuid(),
  code        text        not null unique,
  name        text        not null,
  description text,
  status      text        not null default 'Active' check (status in ('Active','Inactive')),
  created_at  timestamptz not null default now()
);

create table if not exists prod_stock (            -- stock held in locations (tanks hold their own quantity)
  item_id     uuid          not null references prod_items(id)     on delete restrict,
  location_id uuid          not null references prod_locations(id) on delete restrict,
  qty         numeric(14,3) not null default 0 check (qty >= 0),
  updated_at  timestamptz   not null default now(),
  primary key (item_id, location_id)
);

-- ────────────────────────────────────────────────────────────────
--  3. TANKS
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_tanks (
  id           uuid          primary key default gen_random_uuid(),
  tank_code    text          not null unique,
  name         text          not null,
  location_id  uuid          references prod_locations(id) on delete set null,
  location     text,
  capacity     numeric(14,3) not null default 0 check (capacity >= 0),
  current_qty  numeric(14,3) not null default 0 check (current_qty >= 0),
  unit         text          not null default 'MT',
  item_id      uuid          references prod_items(id) on delete restrict,
  product_name text,
  status       text          not null default 'Available'
               check (status in ('Available','Processing','Completed','Maintenance','Disabled')),
  description  text,
  created_by   text,
  created_at   timestamptz   not null default now(),
  updated_at   timestamptz   not null default now(),
  constraint prod_tank_within_capacity check (capacity = 0 or current_qty <= capacity)
);

-- ────────────────────────────────────────────────────────────────
--  4. FILLS  (tank / location  →  tank / location)
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_fills (
  id               uuid          primary key default gen_random_uuid(),
  fill_number      text          not null unique,
  client_token     text          unique,
  source_type      text          not null check (source_type in ('tank','location')),
  source_id        uuid          not null,
  destination_type text          not null check (destination_type in ('tank','location')),
  destination_id   uuid          not null,
  item_id          uuid          references prod_items(id) on delete restrict,
  product_name     text,
  unit             text,
  available_qty    numeric(14,3) not null default 0,
  quantity         numeric(14,3) not null check (quantity > 0),
  fill_date        date          not null default current_date,
  fill_time        time,
  operator_id      uuid          references prod_users(id) on delete set null,
  operator_name    text,
  status           text          not null default 'Draft' check (status in ('Draft','Pending','Approved','Completed','Cancelled')),
  notes            text,
  approved_by      text, approved_at  timestamptz,
  completed_by     text, completed_at timestamptz,
  cancelled_by     text, cancelled_at timestamptz, cancel_reason text,
  created_by       text,
  created_at       timestamptz   not null default now(),
  updated_at       timestamptz   not null default now(),
  constraint prod_fill_src_dst_differ check (not (source_type = destination_type and source_id = destination_id))
);
create index if not exists idx_prod_fills_status on prod_fills(status);
create index if not exists idx_prod_fills_date   on prod_fills(fill_date desc);

-- ────────────────────────────────────────────────────────────────
--  5. PRODUCTION RUNS
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_runs (
  id                      uuid          primary key default gen_random_uuid(),
  production_number       text          not null unique,
  client_token            text          unique,
  tank_id                 uuid          not null references prod_tanks(id) on delete restrict,
  input_item_id           uuid          references prod_items(id) on delete restrict,
  input_product_name      text,
  input_quantity          numeric(14,3) not null check (input_quantity > 0),
  output_item_id          uuid          references prod_items(id) on delete restrict,
  output_product_name     text,
  planned_output_quantity numeric(14,3) not null default 0 check (planned_output_quantity >= 0),
  actual_output_quantity  numeric(14,3) check (actual_output_quantity >= 0),
  unit                    text,
  output_dest_type        text          not null default 'tank' check (output_dest_type in ('tank','location')),
  output_dest_id          uuid,                                   -- null = same tank
  operator_id             uuid          references prod_users(id) on delete set null,
  operator_name           text,
  production_date         date          not null default current_date,
  start_time              time,
  completion_time         time,
  actual_run_seconds      integer       check (actual_run_seconds >= 0),   -- typed in after the run, never a live timer
  actual_run_time         text,
  status                  text          not null default 'Draft' check (status in ('Draft','In Progress','Completed','Cancelled')),
  notes                   text,
  completed_by text, completed_at timestamptz,
  cancelled_by text, cancelled_at timestamptz, cancel_reason text,
  created_by              text,
  created_at              timestamptz   not null default now(),
  updated_at              timestamptz   not null default now()
);
create index if not exists idx_prod_runs_tank   on prod_runs(tank_id);
create index if not exists idx_prod_runs_status on prod_runs(status);
create index if not exists idx_prod_runs_date   on prod_runs(production_date desc);

-- ────────────────────────────────────────────────────────────────
--  6. RECEIPTS / DISPATCH (stock in from outside, stock out to outside)
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_moves (
  id            uuid          primary key default gen_random_uuid(),
  move_no       text          not null unique,
  client_token  text          unique,
  move_type     text          not null check (move_type in ('RECEIPT','DISPATCH')),
  move_date     date          not null default current_date,
  move_time     time,
  location_type text          not null check (location_type in ('tank','location')),
  location_id   uuid          not null,
  item_id       uuid          references prod_items(id) on delete restrict,
  product_name  text,
  unit          text,
  qty           numeric(14,3) not null check (qty > 0),
  party         text,          -- supplier (receipt) or customer (dispatch)
  reference     text,          -- delivery note / invoice
  remarks       text,
  created_by    text,
  created_at    timestamptz   not null default now()
);
create index if not exists idx_prod_moves_date on prod_moves(move_date desc);

-- ────────────────────────────────────────────────────────────────
--  7. LEDGER, AUDIT, SETTINGS, COUNTERS
-- ────────────────────────────────────────────────────────────────
create table if not exists prod_ledger (
  id            uuid          primary key default gen_random_uuid(),
  txn_at        timestamptz   not null default now(),
  txn_type      text          not null,
  ref_type      text          not null,
  ref_id        uuid,
  ref_no        text,
  location_type text          not null check (location_type in ('tank','location')),
  location_id   uuid          not null,
  location_name text,
  item_id       uuid,
  product_name  text,
  unit          text,
  direction     text          not null check (direction in ('IN','OUT')),
  qty           numeric(14,3) not null,
  balance_after numeric(14,3),
  user_name     text,
  notes         text
);
create index if not exists idx_prod_ledger_ref on prod_ledger(ref_type, ref_id);
create index if not exists idx_prod_ledger_loc on prod_ledger(location_type, location_id);

create table if not exists prod_audit (
  id          uuid        primary key default gen_random_uuid(),
  entity      text        not null,
  entity_id   uuid        not null,
  entity_no   text,
  action      text        not null,
  from_status text,
  to_status   text,
  user_name   text,
  details     jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_prod_audit_entity on prod_audit(entity, entity_id, created_at desc);

create table if not exists prod_config (
  key text primary key, value jsonb not null default '{}'::jsonb, updated_by text, updated_at timestamptz not null default now()
);
create table if not exists prod_sequences (seq_type text primary key, last_seq integer not null default 0);

-- updated_at helper (own copy — does not use the Store's)
create or replace function _p_touch() returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
do $$ declare t text; begin
  foreach t in array array['prod_users','prod_items','prod_tanks','prod_fills','prod_runs'] loop
    execute format('drop trigger if exists trg_%s_touch on %I', t, t);
    execute format('create trigger trg_%s_touch before update on %I for each row execute function _p_touch()', t, t);
  end loop;
end $$;

-- tanks / locations are referenced by id from fills, runs, moves and the ledger (polymorphic ids,
-- so the database cannot use a foreign key) — this guard refuses to delete anything that has history
create or replace function _p_guard_delete() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'prod_locations' then
    if exists (select 1 from prod_fills where (source_type = 'location' and source_id = old.id) or (destination_type = 'location' and destination_id = old.id))
       or exists (select 1 from prod_moves  where location_type = 'location' and location_id = old.id)
       or exists (select 1 from prod_runs   where output_dest_type = 'location' and output_dest_id = old.id)
       or exists (select 1 from prod_ledger where location_type = 'location' and location_id = old.id)
    then raise exception 'Location "%" has stock history and cannot be deleted — set it to Inactive instead', old.name; end if;
  else
    if exists (select 1 from prod_fills where (source_type = 'tank' and source_id = old.id) or (destination_type = 'tank' and destination_id = old.id))
       or exists (select 1 from prod_moves  where location_type = 'tank' and location_id = old.id)
       or exists (select 1 from prod_runs   where output_dest_type = 'tank' and output_dest_id = old.id)
       or exists (select 1 from prod_ledger where location_type = 'tank' and location_id = old.id)
    then raise exception 'Tank "%" has history and cannot be deleted — set it to Disabled instead', old.name; end if;
  end if;
  return old;
end $$;
do $$ declare t text; begin
  foreach t in array array['prod_locations','prod_tanks'] loop
    execute format('drop trigger if exists trg_%s_guard on %I', t, t);
    execute format('create trigger trg_%s_guard before delete on %I for each row execute function _p_guard_delete()', t, t);
  end loop;
end $$;

-- RLS (same open-anon pattern as the Store tables: the app enforces roles)
do $$ declare t text; begin
  foreach t in array array['prod_users','prod_categories','prod_items','prod_locations','prod_stock','prod_tanks','prod_fills','prod_runs','prod_moves','prod_ledger','prod_audit','prod_config','prod_sequences'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists allow_anon_all on %I', t);
    execute format('create policy allow_anon_all on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

-- ================================================================
--  FUNCTIONS  (all of them touch prod_* tables ONLY)
-- ================================================================
create or replace function prod_next_no(p_type text, p_prefix text) returns text language plpgsql as $$
declare n integer;
begin
  insert into prod_sequences(seq_type, last_seq) values (p_type, 1)
  on conflict (seq_type) do update set last_seq = prod_sequences.last_seq + 1
  returning last_seq into n;
  return p_prefix || '-' || lpad(n::text, 6, '0');
end $$;

create or replace function _p_audit(p_entity text, p_id uuid, p_no text, p_action text, p_from text, p_to text, p_user text, p_details jsonb default null)
returns void language sql as $$
  insert into prod_audit(entity, entity_id, entity_no, action, from_status, to_status, user_name, details, created_at)
  values (p_entity, p_id, p_no, p_action, p_from, p_to, p_user, p_details, clock_timestamp());
$$;

create or replace function _p_ledger(p_txn text, p_ref_type text, p_ref uuid, p_ref_no text, p_loc_type text, p_loc uuid, p_item uuid, p_dir text, p_qty numeric, p_bal numeric, p_user text, p_notes text default null)
returns void language plpgsql as $$
declare n text; pn text; un text;
begin
  if p_loc_type = 'location' then select name into n from prod_locations where id = p_loc;
  else select name || ' (' || tank_code || ')' into n from prod_tanks where id = p_loc; end if;
  select name, unit into pn, un from prod_items where id = p_item;
  insert into prod_ledger(txn_at, txn_type, ref_type, ref_id, ref_no, location_type, location_id, location_name, item_id, product_name, unit, direction, qty, balance_after, user_name, notes)
  values (clock_timestamp(), p_txn, p_ref_type, p_ref, p_ref_no, p_loc_type, p_loc, n, p_item, pn, un, p_dir, p_qty, p_bal, p_user, p_notes);
end $$;

-- move stock in/out of a LOCATION (row-locked)
create or replace function _p_loc_move(p_loc uuid, p_item uuid, p_delta numeric) returns numeric language plpgsql as $$
declare cur numeric; nxt numeric; l prod_locations%rowtype; it prod_items%rowtype;
begin
  select * into l from prod_locations where id = p_loc;
  if not found then raise exception 'Location not found'; end if;
  if l.status <> 'Active' then raise exception 'Location % is inactive', l.name; end if;
  select * into it from prod_items where id = p_item;
  if not found then raise exception 'Product not found in the Production item list'; end if;
  select qty into cur from prod_stock where item_id = p_item and location_id = p_loc for update;
  if not found then
    if p_delta < 0 then raise exception 'Insufficient stock: % holds 0 % of "%"', l.name, it.unit, it.name; end if;
    insert into prod_stock(item_id, location_id, qty) values (p_item, p_loc, p_delta);
    return p_delta;
  end if;
  nxt := cur + p_delta;
  if nxt < 0 then raise exception 'Insufficient stock: % holds only % % of "%"', l.name, cur, it.unit, it.name; end if;
  update prod_stock set qty = nxt, updated_at = now() where item_id = p_item and location_id = p_loc;
  return nxt;
end $$;

create or replace function _p_available(p_type text, p_id uuid, p_item uuid) returns numeric language plpgsql stable as $$
declare q numeric;
begin
  if p_type = 'location' then select coalesce(qty,0) into q from prod_stock where item_id = p_item and location_id = p_id;
  else select case when item_id = p_item then current_qty else 0 end into q from prod_tanks where id = p_id; end if;
  return coalesce(q, 0);
end $$;

create or replace function _p_tank_out(p_tank uuid, p_item uuid, p_qty numeric) returns numeric language plpgsql as $$
declare t prod_tanks%rowtype;
begin
  select * into t from prod_tanks where id = p_tank for update;
  if not found then raise exception 'Tank not found'; end if;
  if t.status in ('Maintenance','Disabled') then raise exception 'Tank % is % — it cannot be used', t.name, t.status; end if;
  if t.current_qty > 0 and t.item_id is distinct from p_item then raise exception 'Tank % holds "%" — not the selected product', t.name, coalesce(t.product_name,'another product'); end if;
  if t.current_qty < p_qty then raise exception 'Insufficient quantity: Tank % has only % % available', t.name, t.current_qty, t.unit; end if;
  update prod_tanks set current_qty = current_qty - p_qty,
         item_id      = case when current_qty - p_qty = 0 then null else item_id end,
         product_name = case when current_qty - p_qty = 0 then null else product_name end,
         status       = case when current_qty - p_qty = 0 and status = 'Completed' then 'Available' else status end
   where id = p_tank;
  return t.current_qty - p_qty;
end $$;

create or replace function _p_tank_in(p_tank uuid, p_item uuid, p_qty numeric) returns numeric language plpgsql as $$
declare t prod_tanks%rowtype; it prod_items%rowtype;
begin
  select * into t from prod_tanks where id = p_tank for update;
  if not found then raise exception 'Tank not found'; end if;
  if t.status in ('Maintenance','Disabled') then raise exception 'Tank % is % — it cannot receive product', t.name, t.status; end if;
  if t.current_qty > 0 and t.item_id is distinct from p_item then raise exception 'Tank % already holds "%" — empty it first or choose another tank', t.name, coalesce(t.product_name,'another product'); end if;
  if t.capacity > 0 and t.current_qty + p_qty > t.capacity then
    raise exception 'Tank % capacity exceeded: free space is % % but % was requested', t.name, (t.capacity - t.current_qty), t.unit, p_qty; end if;
  select * into it from prod_items where id = p_item;
  if not found then raise exception 'Product not found in the Production item list'; end if;
  update prod_tanks set current_qty = current_qty + p_qty,
         item_id      = case when current_qty = 0 or item_id is null then p_item else item_id end,
         product_name = case when current_qty = 0 or product_name is null then it.name else product_name end
   where id = p_tank;
  return t.current_qty + p_qty;
end $$;

-- ── login (server-side password check; the hash never leaves the database) ──
create or replace function prod_login(p_username text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u prod_users%rowtype;
begin
  select * into u from prod_users where lower(username) = lower(trim(p_username)) and status = 'Active';
  if not found or u.password_hash <> crypt(p_password, u.password_hash) then return null; end if;
  return jsonb_build_object('id', u.id, 'username', u.username, 'name', u.name, 'role', u.role, 'pages', u.pages, 'can_approve', u.can_approve, 'status', u.status);
end $$;

-- create / update a Production user (password is hashed here)
create or replace function prod_user_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u prod_users%rowtype; pid uuid := nullif(p->>'id','')::uuid; pw text := nullif(p->>'password','');
begin
  if coalesce(trim(p->>'username'),'') = '' or coalesce(trim(p->>'name'),'') = '' then raise exception 'Username and name are required'; end if;
  if pid is null then
    if pw is null or length(pw) < 4 then raise exception 'Password must be at least 4 characters'; end if;
    if exists (select 1 from prod_users where lower(username) = lower(trim(p->>'username'))) then raise exception 'Username "%" already exists', trim(p->>'username'); end if;
    insert into prod_users(username, name, password_hash, role, status, pages, can_approve)
    values (trim(p->>'username'), trim(p->>'name'), crypt(pw, gen_salt('bf')), coalesce(nullif(p->>'role',''),'Operator'), coalesce(nullif(p->>'status',''),'Active'),
            coalesce(nullif(p->>'pages',''),'dashboard'), coalesce((p->>'can_approve')::boolean,false)) returning * into u;
  else
    if exists (select 1 from prod_users where lower(username) = lower(trim(p->>'username')) and id <> pid) then raise exception 'Username "%" already exists', trim(p->>'username'); end if;
    update prod_users set username = trim(p->>'username'), name = trim(p->>'name'), role = coalesce(nullif(p->>'role',''), role), status = coalesce(nullif(p->>'status',''), status),
           pages = coalesce(nullif(p->>'pages',''), pages), can_approve = coalesce((p->>'can_approve')::boolean, can_approve),
           password_hash = case when pw is not null then crypt(pw, gen_salt('bf')) else password_hash end
     where id = pid returning * into u;
    if not found then raise exception 'User not found'; end if;
  end if;
  return jsonb_build_object('id', u.id, 'username', u.username, 'name', u.name, 'role', u.role, 'pages', u.pages, 'can_approve', u.can_approve, 'status', u.status);
end $$;

-- a user changes their OWN password (must know the current one)
create or replace function prod_change_password(p_user uuid, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u prod_users%rowtype;
begin
  select * into u from prod_users where id = p_user and status = 'Active';
  if not found or u.password_hash <> crypt(p_old, u.password_hash) then raise exception 'Current password is incorrect'; end if;
  if p_new is null or length(p_new) < 4 then raise exception 'New password must be at least 4 characters'; end if;
  update prod_users set password_hash = crypt(p_new, gen_salt('bf')) where id = p_user;
  return jsonb_build_object('ok', true);
end $$;

-- ── tanks ──
create or replace function prod_tank_create(p jsonb) returns jsonb language plpgsql as $$
declare t prod_tanks%rowtype; q numeric := coalesce((p->>'opening_qty')::numeric, 0); it uuid := nullif(p->>'item_id','')::uuid; u text := p->>'user';
begin
  if coalesce(trim(p->>'tank_code'),'') = '' or coalesce(trim(p->>'name'),'') = '' then raise exception 'Tank code and name are required'; end if;
  if q > 0 and it is null then raise exception 'Select the product held in the tank for the opening quantity'; end if;
  if exists (select 1 from prod_tanks where lower(tank_code) = lower(trim(p->>'tank_code'))) then raise exception 'Tank code "%" already exists', trim(p->>'tank_code'); end if;
  insert into prod_tanks(tank_code, name, location_id, location, capacity, unit, status, description, created_by)
  values (trim(p->>'tank_code'), trim(p->>'name'), nullif(p->>'location_id','')::uuid, p->>'location', coalesce((p->>'capacity')::numeric,0),
          coalesce(nullif(p->>'unit',''),'MT'), coalesce(nullif(p->>'status',''),'Available'), p->>'description', u) returning * into t;
  if q > 0 then
    perform _p_tank_in(t.id, it, q); select * into t from prod_tanks where id = t.id;
    perform _p_ledger('TANK_OPENING','TANK', t.id, t.tank_code, 'tank', t.id, it, 'IN', q, t.current_qty, u, 'Opening quantity');
  end if;
  perform _p_audit('tank', t.id, t.tank_code, 'Created', null, t.status, u, jsonb_build_object('opening_qty', q));
  return to_jsonb(t);
end $$;

create or replace function prod_tank_adjust(p_tank uuid, p_new_qty numeric, p_item uuid, p_user text, p_reason text) returns jsonb language plpgsql as $$
declare t prod_tanks%rowtype; d numeric; it prod_items%rowtype;
begin
  if p_new_qty < 0 then raise exception 'Quantity cannot be negative'; end if;
  select * into t from prod_tanks where id = p_tank for update;
  if not found then raise exception 'Tank not found'; end if;
  if t.capacity > 0 and p_new_qty > t.capacity then raise exception 'Quantity % exceeds tank capacity %', p_new_qty, t.capacity; end if;
  if p_new_qty > 0 and coalesce(p_item, t.item_id) is null then raise exception 'Select the product held in the tank'; end if;
  d := p_new_qty - t.current_qty;
  if p_new_qty > 0 then select * into it from prod_items where id = coalesce(p_item, t.item_id); end if;
  update prod_tanks set current_qty = p_new_qty, item_id = case when p_new_qty = 0 then null else it.id end,
         product_name = case when p_new_qty = 0 then null else it.name end where id = p_tank returning * into t;
  if d <> 0 then perform _p_ledger('TANK_ADJUST','TANK', t.id, t.tank_code, 'tank', t.id, it.id, case when d > 0 then 'IN' else 'OUT' end, abs(d), t.current_qty, p_user, coalesce(p_reason,'Quantity correction')); end if;
  perform _p_audit('tank', t.id, t.tank_code, 'Quantity adjusted', null, t.status, p_user, jsonb_build_object('new_qty', p_new_qty, 'delta', d, 'reason', p_reason));
  return to_jsonb(t);
end $$;

-- correct the stock of one item in one location (physical count)
create or replace function prod_loc_adjust(p_loc uuid, p_item uuid, p_new_qty numeric, p_user text, p_reason text) returns jsonb language plpgsql as $$
declare cur numeric := 0; bal numeric;
begin
  if p_new_qty < 0 then raise exception 'Quantity cannot be negative'; end if;
  select qty into cur from prod_stock where item_id = p_item and location_id = p_loc;
  cur := coalesce(cur, 0);
  if p_new_qty = cur then return jsonb_build_object('qty', cur, 'changed', false); end if;
  bal := _p_loc_move(p_loc, p_item, p_new_qty - cur);
  perform _p_ledger('LOC_ADJUST','LOCATION', p_loc, null, 'location', p_loc, p_item, case when p_new_qty > cur then 'IN' else 'OUT' end, abs(p_new_qty - cur), bal, p_user, coalesce(p_reason,'Stock correction'));
  perform _p_audit('location', p_loc, null, 'Stock adjusted', null, null, p_user, jsonb_build_object('item', p_item, 'new_qty', p_new_qty, 'delta', p_new_qty - cur, 'reason', p_reason));
  return jsonb_build_object('qty', bal, 'changed', true);
end $$;

-- ── receipts / dispatch ──
create or replace function prod_move_create(p jsonb) returns jsonb language plpgsql as $$
declare m prod_moves%rowtype; tok text := nullif(p->>'client_token',''); mt text := upper(coalesce(p->>'move_type',''));
        lt text := p->>'location_type'; lid uuid := (p->>'location_id')::uuid; it uuid := nullif(p->>'item_id','')::uuid;
        q numeric := (p->>'qty')::numeric; itm prod_items%rowtype; bal numeric; num text; u text := p->>'user';
begin
  if tok is not null then select * into m from prod_moves where client_token = tok; if found then return to_jsonb(m); end if; end if;
  if mt not in ('RECEIPT','DISPATCH') then raise exception 'Invalid movement type'; end if;
  if lt not in ('tank','location') then raise exception 'Choose a tank or a location'; end if;
  if it is null then raise exception 'Select a product'; end if;
  if q is null or q <= 0 then raise exception 'Quantity must be greater than zero'; end if;
  select * into itm from prod_items where id = it; if not found then raise exception 'Product not found'; end if;
  num := prod_next_no(case when mt = 'RECEIPT' then 'move_rcpt' else 'move_disp' end, case when mt = 'RECEIPT' then 'RCP' else 'DSP' end);
  insert into prod_moves(move_no, client_token, move_type, move_date, move_time, location_type, location_id, item_id, product_name, unit, qty, party, reference, remarks, created_by)
  values (num, tok, mt, coalesce(nullif(p->>'move_date','')::date, current_date), nullif(p->>'move_time','')::time, lt, lid, it, itm.name, itm.unit, q, p->>'party', p->>'reference', p->>'remarks', u)
  on conflict (client_token) do nothing returning * into m;
  if not found then select * into m from prod_moves where client_token = tok; return to_jsonb(m); end if;
  if mt = 'RECEIPT' then
    bal := case when lt = 'tank' then _p_tank_in(lid, it, q) else _p_loc_move(lid, it, q) end;
  else
    bal := case when lt = 'tank' then _p_tank_out(lid, it, q) else _p_loc_move(lid, it, -q) end;
  end if;
  perform _p_ledger(mt, 'MOVE', m.id, m.move_no, lt, lid, it, case when mt = 'RECEIPT' then 'IN' else 'OUT' end, q, bal, u, coalesce(m.party, m.reference));
  perform _p_audit('move', m.id, m.move_no, initcap(lower(mt)) || ' recorded', null, 'Completed', u, jsonb_build_object('qty', q, 'product', itm.name));
  return to_jsonb(m);
end $$;

-- ── fill ──
create or replace function prod_fill_create(p jsonb) returns jsonb language plpgsql as $$
declare f prod_fills%rowtype; tok text := nullif(p->>'client_token',''); st text := coalesce(nullif(p->>'status',''),'Draft');
        sty text := p->>'source_type'; dty text := p->>'destination_type'; sid uuid := (p->>'source_id')::uuid; did uuid := (p->>'destination_id')::uuid;
        it uuid := nullif(p->>'item_id','')::uuid; q numeric := (p->>'quantity')::numeric; av numeric; itm prod_items%rowtype; num text; u text := p->>'user';
begin
  if tok is not null then select * into f from prod_fills where client_token = tok; if found then return to_jsonb(f); end if; end if;
  if st not in ('Draft','Pending') then raise exception 'A new fill can only start as Draft or Pending'; end if;
  if sty not in ('tank','location') or dty not in ('tank','location') then raise exception 'Invalid source or destination'; end if;
  if sty = dty and sid = did then raise exception 'Source and destination must be different'; end if;
  if it is null then raise exception 'Select a product'; end if;
  if q is null or q <= 0 then raise exception 'Fill quantity must be greater than zero'; end if;
  select * into itm from prod_items where id = it; if not found then raise exception 'Product not found'; end if;
  av := _p_available(sty, sid, it);
  if q > av then raise exception 'Cannot fill % — only % % available at the source', q, av, itm.unit; end if;
  num := prod_next_no('fill', coalesce(nullif(p->>'prefix',''),'FIL'));
  insert into prod_fills(fill_number, client_token, source_type, source_id, destination_type, destination_id, item_id, product_name, unit, available_qty, quantity, fill_date, fill_time, operator_id, operator_name, status, notes, created_by)
  values (num, tok, sty, sid, dty, did, it, itm.name, itm.unit, av, q, coalesce(nullif(p->>'fill_date','')::date, current_date), nullif(p->>'fill_time','')::time,
          nullif(p->>'operator_id','')::uuid, p->>'operator_name', st, p->>'notes', u)
  on conflict (client_token) do nothing returning * into f;
  if not found then select * into f from prod_fills where client_token = tok; return to_jsonb(f); end if;
  perform _p_audit('fill', f.id, f.fill_number, 'Created', null, f.status, u, jsonb_build_object('quantity', q, 'product', itm.name));
  return to_jsonb(f);
end $$;

create or replace function prod_fill_set_status(p_id uuid, p_status text, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare f prod_fills%rowtype; old text;
begin
  select * into f from prod_fills where id = p_id for update;
  if not found then raise exception 'Fill not found'; end if;
  old := f.status;
  if old = p_status then return to_jsonb(f); end if;
  if old in ('Completed','Cancelled') then raise exception 'Fill % is already % and cannot be changed', f.fill_number, old; end if;
  if not ((old = 'Draft' and p_status in ('Pending','Cancelled')) or (old = 'Pending' and p_status in ('Approved','Cancelled')) or (old = 'Approved' and p_status = 'Cancelled')) then
    raise exception 'Cannot change a % fill to %', old, p_status; end if;
  update prod_fills set status = p_status,
         approved_by  = case when p_status = 'Approved'  then p_user else approved_by end,  approved_at  = case when p_status = 'Approved'  then now() else approved_at end,
         cancelled_by = case when p_status = 'Cancelled' then p_user else cancelled_by end, cancelled_at = case when p_status = 'Cancelled' then now() else cancelled_at end,
         cancel_reason= case when p_status = 'Cancelled' then p_reason else cancel_reason end where id = p_id returning * into f;
  perform _p_audit('fill', f.id, f.fill_number, 'Status changed', old, p_status, p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(f);
end $$;

create or replace function prod_fill_complete(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare f prod_fills%rowtype; bal numeric; old text;
begin
  select * into f from prod_fills where id = p_id for update;
  if not found then raise exception 'Fill not found'; end if;
  old := f.status;
  if old = 'Completed' then raise exception 'Fill % is already completed — stock was not moved again', f.fill_number; end if;
  if old = 'Cancelled' then raise exception 'Fill % is cancelled', f.fill_number; end if;
  if not exists (select 1 from prod_items where id = f.item_id) then raise exception 'The product of this fill no longer exists'; end if;
  bal := case when f.source_type = 'location' then _p_loc_move(f.source_id, f.item_id, -f.quantity) else _p_tank_out(f.source_id, f.item_id, f.quantity) end;
  perform _p_ledger('FILL_OUT','FILL', f.id, f.fill_number, f.source_type, f.source_id, f.item_id, 'OUT', f.quantity, bal, p_user, 'Fill to ' || f.destination_type);
  bal := case when f.destination_type = 'location' then _p_loc_move(f.destination_id, f.item_id, f.quantity) else _p_tank_in(f.destination_id, f.item_id, f.quantity) end;
  perform _p_ledger('FILL_IN','FILL', f.id, f.fill_number, f.destination_type, f.destination_id, f.item_id, 'IN', f.quantity, bal, p_user, 'Fill from ' || f.source_type);
  update prod_fills set status = 'Completed', completed_by = p_user, completed_at = now(), approved_by = coalesce(approved_by, p_user), approved_at = coalesce(approved_at, now()) where id = p_id returning * into f;
  perform _p_audit('fill', f.id, f.fill_number, 'Completed — stock moved', old, 'Completed', p_user, jsonb_build_object('quantity', f.quantity, 'product', f.product_name));
  return to_jsonb(f);
end $$;

-- ── production runs ──
create or replace function _p_tank_usable(p_tank uuid, p_exclude uuid default null) returns void language plpgsql as $$
declare t prod_tanks%rowtype;
begin
  select * into t from prod_tanks where id = p_tank; if not found then raise exception 'Tank not found'; end if;
  if t.status in ('Maintenance','Disabled') then raise exception 'Tank % is % — it cannot be used for production', t.name, t.status; end if;
  if exists (select 1 from prod_runs where tank_id = p_tank and status = 'In Progress' and (p_exclude is null or id <> p_exclude)) then raise exception 'Tank % already has a production in progress', t.name; end if;
end $$;

create or replace function prod_run_create(p jsonb) returns jsonb language plpgsql as $$
declare r prod_runs%rowtype; tok text := nullif(p->>'client_token',''); st text := coalesce(nullif(p->>'status',''),'Draft'); tk prod_tanks%rowtype; tid uuid := (p->>'tank_id')::uuid;
        q numeric := (p->>'input_quantity')::numeric; outi uuid; outn text; num text; u text := p->>'user'; odt text := coalesce(nullif(p->>'output_dest_type',''),'tank'); dest uuid := nullif(p->>'output_dest_id','')::uuid;
begin
  if tok is not null then select * into r from prod_runs where client_token = tok; if found then return to_jsonb(r); end if; end if;
  if st not in ('Draft','In Progress') then raise exception 'A new production can only start as Draft or In Progress'; end if;
  select * into tk from prod_tanks where id = tid; if not found then raise exception 'Select a tank'; end if;
  if tk.item_id is null or tk.current_qty <= 0 then raise exception 'Tank % is empty — fill it with the input material first', tk.name; end if;
  if q is null or q <= 0 then raise exception 'Input quantity must be greater than zero'; end if;
  if q > tk.current_qty then raise exception 'Input quantity % exceeds the % % in Tank %', q, tk.current_qty, tk.unit, tk.name; end if;
  if odt = 'location' and dest is null then raise exception 'Select the location that receives the output'; end if;
  if st = 'In Progress' then perform _p_tank_usable(tid); end if;
  outi := coalesce(nullif(p->>'output_item_id','')::uuid, tk.item_id);
  select name into outn from prod_items where id = outi;
  num := prod_next_no('run', coalesce(nullif(p->>'prefix',''),'TPR'));
  insert into prod_runs(production_number, client_token, tank_id, input_item_id, input_product_name, input_quantity, output_item_id, output_product_name, planned_output_quantity, unit, output_dest_type, output_dest_id,
         operator_id, operator_name, production_date, start_time, status, notes, created_by)
  values (num, tok, tid, tk.item_id, tk.product_name, q, outi, outn, coalesce((p->>'planned_output_quantity')::numeric, 0), coalesce(nullif(p->>'unit',''), tk.unit),
          odt, case when dest is not null and dest <> tid then dest else null end, nullif(p->>'operator_id','')::uuid, p->>'operator_name',
          coalesce(nullif(p->>'production_date','')::date, current_date), nullif(p->>'start_time','')::time, st, p->>'notes', u)
  on conflict (client_token) do nothing returning * into r;
  if not found then select * into r from prod_runs where client_token = tok; return to_jsonb(r); end if;
  if st = 'In Progress' then update prod_tanks set status = 'Processing' where id = tid; end if;
  perform _p_audit('run', r.id, r.production_number, 'Created', null, r.status, u, jsonb_build_object('tank', tk.name, 'input_qty', q));
  return to_jsonb(r);
end $$;

create or replace function prod_run_start(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_runs%rowtype;
begin
  select * into r from prod_runs where id = p_id for update; if not found then raise exception 'Production not found'; end if;
  if r.status = 'In Progress' then return to_jsonb(r); end if;
  if r.status <> 'Draft' then raise exception 'Production % is % and cannot be started', r.production_number, r.status; end if;
  perform _p_tank_usable(r.tank_id, r.id);
  update prod_runs set status = 'In Progress' where id = p_id returning * into r;
  update prod_tanks set status = 'Processing' where id = r.tank_id;
  perform _p_audit('run', r.id, r.production_number, 'Started', 'Draft', 'In Progress', p_user);
  return to_jsonb(r);
end $$;

create or replace function prod_run_complete(p_id uuid, p jsonb) returns jsonb language plpgsql as $$
declare r prod_runs%rowtype; tk prod_tanks%rowtype; old text; u text := p->>'user'; outq numeric := (p->>'actual_output_quantity')::numeric;
        secs integer; bal numeric; outi uuid; outn text; keep_in_tank boolean; to_other_tank boolean; v_type text; v_dest uuid;
begin
  select * into r from prod_runs where id = p_id for update; if not found then raise exception 'Production not found'; end if;
  old := r.status;
  if old = 'Completed' then raise exception 'Production % is already completed — stock was not moved again', r.production_number; end if;
  if old = 'Cancelled' then raise exception 'Production % is cancelled', r.production_number; end if;
  if outq is null or outq < 0 then raise exception 'Enter the actual output quantity'; end if;
  secs := coalesce((p->>'run_hours')::int,0) * 3600 + coalesce((p->>'run_minutes')::int,0) * 60 + coalesce((p->>'run_seconds')::int,0);
  if coalesce((p->>'run_minutes')::int,0) not between 0 and 59 or coalesce((p->>'run_seconds')::int,0) not between 0 and 59 then raise exception 'Minutes and seconds must be between 0 and 59'; end if;
  if secs <= 0 then raise exception 'Enter the Actual Run Time (hours / minutes) the production took'; end if;
  select * into tk from prod_tanks where id = r.tank_id for update;
  if tk.status in ('Maintenance','Disabled') then raise exception 'Tank % is % — cannot complete production', tk.name, tk.status; end if;
  outi := coalesce(nullif(p->>'output_item_id','')::uuid, r.output_item_id, r.input_item_id);
  select name into outn from prod_items where id = outi;
  v_type := coalesce(nullif(p->>'output_dest_type',''), r.output_dest_type);
  if p ? 'output_dest_type' then v_dest := nullif(p->>'output_dest_id','')::uuid; else v_dest := r.output_dest_id; end if;
  if v_type = 'tank' and v_dest = r.tank_id then v_dest := null; end if;
  keep_in_tank := (v_type = 'tank' and v_dest is null); to_other_tank := (v_type = 'tank' and v_dest is not null);
  if v_type = 'location' and v_dest is null then raise exception 'Select the location that receives the output'; end if;
  bal := _p_tank_out(r.tank_id, r.input_item_id, r.input_quantity);
  perform _p_ledger('PROD_INPUT','RUN', r.id, r.production_number, 'tank', r.tank_id, r.input_item_id, 'OUT', r.input_quantity, bal, u, 'Production input');
  if outq > 0 then
    if keep_in_tank then
      bal := _p_tank_in(r.tank_id, outi, outq);
      perform _p_ledger('PROD_OUTPUT','RUN', r.id, r.production_number, 'tank', r.tank_id, outi, 'IN', outq, bal, u, 'Production output');
    elsif to_other_tank then
      bal := _p_tank_in(v_dest, outi, outq);
      perform _p_ledger('PROD_OUTPUT','RUN', r.id, r.production_number, 'tank', v_dest, outi, 'IN', outq, bal, u, 'Production output (from ' || r.production_number || ')');
    else
      bal := _p_loc_move(v_dest, outi, outq);
      perform _p_ledger('PROD_OUTPUT','RUN', r.id, r.production_number, 'location', v_dest, outi, 'IN', outq, bal, u, 'Production output');
    end if;
  end if;
  update prod_runs set status = 'Completed', actual_output_quantity = outq, actual_run_seconds = secs,
      actual_run_time = lpad((secs/3600)::text,2,'0') || ':' || lpad(((secs%3600)/60)::text,2,'0') || ':' || lpad((secs%60)::text,2,'0'),
      start_time = coalesce(nullif(p->>'start_time','')::time, start_time), completion_time = nullif(p->>'completion_time','')::time,
      output_item_id = outi, output_product_name = coalesce(outn, output_product_name),
      output_dest_type = case when v_type = 'location' then 'location' else 'tank' end, output_dest_id = v_dest,
      production_date = coalesce(nullif(p->>'production_date','')::date, production_date), notes = coalesce(nullif(p->>'notes',''), notes),
      completed_by = u, completed_at = now() where id = p_id returning * into r;
  update prod_tanks set status = case when keep_in_tank and current_qty > 0 then 'Completed' else 'Available' end where id = r.tank_id;
  perform _p_audit('run', r.id, r.production_number, 'Completed — stock moved', old, 'Completed', u, jsonb_build_object('input_qty', r.input_quantity, 'output_qty', outq, 'run_time', r.actual_run_time));
  return to_jsonb(r);
end $$;

create or replace function prod_run_cancel(p_id uuid, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare r prod_runs%rowtype; old text;
begin
  select * into r from prod_runs where id = p_id for update; if not found then raise exception 'Production not found'; end if;
  old := r.status;
  if old = 'Cancelled' then return to_jsonb(r); end if;
  if old = 'Completed' then raise exception 'Production % is completed and cannot be cancelled', r.production_number; end if;
  update prod_runs set status = 'Cancelled', cancelled_by = p_user, cancelled_at = now(), cancel_reason = p_reason where id = p_id returning * into r;
  if old = 'In Progress' then update prod_tanks set status = 'Available' where id = r.tank_id and status = 'Processing'; end if;
  perform _p_audit('run', r.id, r.production_number, 'Cancelled', old, 'Cancelled', p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(r);
end $$;

-- ================================================================
--  PRODUCTION ORDERS  &  CONSUMPTION   (moved here from the Store app)
--  All objects are prod_* only — nothing references the Store.
-- ================================================================
create table if not exists prod_orders (
  id              uuid          primary key default gen_random_uuid(),
  order_no        text          not null unique,
  client_token    text          unique,
  order_date      date          not null default current_date,
  tank_id         uuid          not null references prod_tanks(id) on delete restrict,   -- the location is a TANK
  item_id         uuid          not null references prod_items(id) on delete restrict,
  product_name    text,
  batch_no        text,
  output_qty      numeric(14,3) not null check (output_qty > 0),
  unit            text,
  hours_taken     numeric(8,2)  not null default 0 check (hours_taken >= 0),               -- typed by hand; no start/end time, no timer
  remarks         text,
  status          text          not null default 'Pending Approval' check (status in ('Draft','Pending Approval','Approved','Rejected')),
  submitted_by    text, approved_by text, approved_at timestamptz, reject_reason text,
  created_by      text,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);
create index if not exists idx_prod_orders_status on prod_orders(status);
create index if not exists idx_prod_orders_date   on prod_orders(order_date desc);
create index if not exists idx_prod_orders_tank   on prod_orders(tank_id);

-- raw-material usage is its own module: planned (e.g. 3 MT) versus actual (e.g. 3.8 MT)
create table if not exists prod_consumptions (
  id              uuid          primary key default gen_random_uuid(),
  cons_no         text          not null unique,
  client_token    text          unique,
  cons_date       date          not null default current_date,
  order_id        uuid          references prod_orders(id) on delete restrict,           -- optional link to a production order
  for_item_id     uuid          references prod_items(id) on delete restrict,            -- the product this raw material was used for (e.g. LABSA 3 MT)
  for_product     text,
  item_id         uuid          not null references prod_items(id) on delete restrict,
  product_name    text,
  source_tank_id  uuid          references prod_tanks(id) on delete restrict,            -- optional: deduct the actual quantity from this tank
  planned_qty     numeric(14,3) not null default 0 check (planned_qty >= 0),
  actual_qty      numeric(14,3) not null check (actual_qty > 0),
  unit            text,
  remarks         text,
  status          text          not null default 'Pending Approval' check (status in ('Draft','Pending Approval','Approved','Rejected')),
  submitted_by    text, approved_by text, approved_at timestamptz, reject_reason text,
  created_by      text,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);
alter table prod_consumptions add column if not exists for_item_id uuid references prod_items(id) on delete restrict;
alter table prod_consumptions add column if not exists for_product text;
create index if not exists idx_prod_cons_status on prod_consumptions(status);
create index if not exists idx_prod_cons_date   on prod_consumptions(cons_date desc);

-- a consumption voucher holds one or more raw-material lines
create table if not exists prod_consumption_items (
  id              uuid          primary key default gen_random_uuid(),
  cons_id         uuid          not null references prod_consumptions(id) on delete cascade,
  item_id         uuid          not null references prod_items(id) on delete restrict,
  product_name    text,
  source_tank_id  uuid          references prod_tanks(id) on delete restrict,           -- optional: deduct from this tank on approval
  planned_qty     numeric(14,3) not null default 0 check (planned_qty >= 0),
  actual_qty      numeric(14,3) not null check (actual_qty > 0),
  unit            text,
  remarks         text,
  created_at      timestamptz   not null default now()
);
create index if not exists idx_prod_cons_items_cons on prod_consumption_items(cons_id);
-- (older single-item vouchers) the item / quantity now live on the lines
alter table prod_consumptions alter column item_id drop not null;
alter table prod_consumptions alter column actual_qty drop not null;
alter table prod_consumptions drop constraint if exists prod_consumptions_actual_qty_check;
insert into prod_consumption_items(cons_id, item_id, product_name, source_tank_id, planned_qty, actual_qty, unit, remarks)
select c.id, c.item_id, c.product_name, c.source_tank_id, c.planned_qty, c.actual_qty, c.unit, null
  from prod_consumptions c
 where c.item_id is not null and c.actual_qty > 0 and not exists (select 1 from prod_consumption_items l where l.cons_id = c.id);

do $$ declare t text; begin
  foreach t in array array['prod_orders','prod_consumptions','prod_consumption_items'] loop
    if t <> 'prod_consumption_items' then
      execute format('drop trigger if exists trg_%s_touch on %I', t, t);
      execute format('create trigger trg_%s_touch before update on %I for each row execute function _p_touch()', t, t);
    end if;
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists allow_anon_all on %I', t);
    execute format('create policy allow_anon_all on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

create or replace function prod_order_create(p jsonb) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; tok text := nullif(p->>'client_token',''); tk prod_tanks%rowtype; it prod_items%rowtype;
        q numeric := (p->>'output_qty')::numeric; h numeric := coalesce((p->>'hours_taken')::numeric, 0);
        st text := coalesce(nullif(p->>'status',''),'Pending Approval'); u text := p->>'user'; num text;
begin
  if tok is not null then select * into r from prod_orders where client_token = tok; if found then return to_jsonb(r); end if; end if;
  if st not in ('Draft','Pending Approval') then raise exception 'A new production order can only be Draft or Pending Approval'; end if;
  select * into tk from prod_tanks where id = (p->>'tank_id')::uuid; if not found then raise exception 'Select a tank'; end if;
  select * into it from prod_items where id = (p->>'item_id')::uuid; if not found then raise exception 'Select the product produced'; end if;
  if q is null or q <= 0 then raise exception 'Enter the quantity produced'; end if;
  if h < 0 or h > 9999 then raise exception 'Hours taken is not valid'; end if;
  if st = 'Pending Approval' and h <= 0 then raise exception 'Enter the Hours taken'; end if;
  num := prod_next_no('order', coalesce(nullif(p->>'prefix',''),'PRO'));
  insert into prod_orders(order_no, client_token, order_date, tank_id, item_id, product_name, batch_no, output_qty, unit, hours_taken, remarks, status, submitted_by, created_by)
  values (num, tok, coalesce(nullif(p->>'order_date','')::date, current_date), tk.id, it.id, it.name, nullif(p->>'batch_no',''), q, coalesce(it.unit, tk.unit), h, p->>'remarks', st,
          case when st = 'Pending Approval' then u end, u)
  on conflict (client_token) do nothing returning * into r;
  if not found then select * into r from prod_orders where client_token = tok; return to_jsonb(r); end if;
  perform _p_audit('order', r.id, r.order_no, 'Created', null, r.status, u, jsonb_build_object('tank', tk.name, 'qty', q, 'hours', h));
  return to_jsonb(r);
end $$;

create or replace function prod_order_submit(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  if r.status = 'Pending Approval' then return to_jsonb(r); end if;
  if r.status not in ('Draft','Rejected') then raise exception 'Order % is % and cannot be submitted', r.order_no, r.status; end if;
  if r.hours_taken <= 0 then raise exception 'Enter the Hours taken before submitting'; end if;
  update prod_orders set status = 'Pending Approval', submitted_by = p_user, reject_reason = null where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Submitted', 'Draft', 'Pending Approval', p_user);
  return to_jsonb(r);
end $$;

-- approval adds the produced quantity to the tank (row-locked, capacity + same-product checks, ledger + audit)
create or replace function prod_order_approve(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; bal numeric;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  if r.status = 'Approved' then raise exception 'Order % is already approved — stock was not added again', r.order_no; end if;
  if r.status <> 'Pending Approval' then raise exception 'Order % is % and cannot be approved', r.order_no, r.status; end if;
  bal := _p_tank_in(r.tank_id, r.item_id, r.output_qty);
  perform _p_ledger('ORDER_OUTPUT', 'ORDER', r.id, r.order_no, 'tank', r.tank_id, r.item_id, 'IN', r.output_qty, bal, p_user, 'Production order output');
  update prod_tanks set status = 'Completed' where id = r.tank_id and status = 'Available';
  update prod_orders set status = 'Approved', approved_by = p_user, approved_at = now() where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Approved — stock added', 'Pending Approval', 'Approved', p_user, jsonb_build_object('qty', r.output_qty, 'hours', r.hours_taken));
  return to_jsonb(r);
end $$;

create or replace function prod_order_reject(p_id uuid, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; old text;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  old := r.status;
  if old = 'Rejected' then return to_jsonb(r); end if;
  if old <> 'Pending Approval' then raise exception 'Order % is % and cannot be rejected', r.order_no, old; end if;
  update prod_orders set status = 'Rejected', approved_by = p_user, approved_at = now(), reject_reason = p_reason where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Rejected', old, 'Rejected', p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(r);
end $$;

create or replace function prod_cons_create(p jsonb) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; tok text := nullif(p->>'client_token',''); it prod_items%rowtype; tk prod_tanks%rowtype; fi prod_items%rowtype; fid uuid := nullif(p->>'for_item_id','')::uuid;
        st text := coalesce(nullif(p->>'status',''),'Pending Approval'); u text := p->>'user'; num text; oid uuid := nullif(p->>'order_id','')::uuid;
        ln jsonb; lines jsonb := p->'lines'; ac numeric; pl numeric; tid uuid; n int := 0;
begin
  if tok is not null then select * into r from prod_consumptions where client_token = tok; if found then return to_jsonb(r); end if; end if;
  if st not in ('Draft','Pending Approval') then raise exception 'A new consumption can only be Draft or Pending Approval'; end if;
  if lines is null or jsonb_typeof(lines) <> 'array' or jsonb_array_length(lines) = 0 then raise exception 'Add at least one raw material'; end if;
  if oid is not null and not exists (select 1 from prod_orders where id = oid) then raise exception 'Production order not found'; end if;
  if fid is not null then select * into fi from prod_items where id = fid; if not found then raise exception 'Product not found'; end if; end if;
  -- validate every line before anything is written
  for ln in select * from jsonb_array_elements(lines) loop
    select * into it from prod_items where id = nullif(ln->>'item_id','')::uuid; if not found then raise exception 'Select the raw material on every line'; end if;
    ac := (ln->>'actual_qty')::numeric; pl := coalesce((ln->>'planned_qty')::numeric, 0);
    if ac is null or ac <= 0 then raise exception 'Enter the actual quantity used for %', it.name; end if;
    if pl < 0 then raise exception 'Planned quantity cannot be negative'; end if;
    tid := nullif(ln->>'source_tank_id','')::uuid;
    if tid is not null then select * into tk from prod_tanks where id = tid; if not found then raise exception 'Tank not found'; end if; end if;
  end loop;
  num := prod_next_no('cons', coalesce(nullif(p->>'prefix',''),'CON'));
  insert into prod_consumptions(cons_no, client_token, cons_date, order_id, for_item_id, for_product, remarks, status, submitted_by, created_by)
  values (num, tok, coalesce(nullif(p->>'cons_date','')::date, current_date), oid, fid, fi.name, p->>'remarks', st, case when st = 'Pending Approval' then u end, u)
  on conflict (client_token) do nothing returning * into r;
  if not found then select * into r from prod_consumptions where client_token = tok; return to_jsonb(r); end if;
  for ln in select * from jsonb_array_elements(lines) loop
    select * into it from prod_items where id = (ln->>'item_id')::uuid;
    insert into prod_consumption_items(cons_id, item_id, product_name, source_tank_id, planned_qty, actual_qty, unit, remarks)
    values (r.id, it.id, it.name, nullif(ln->>'source_tank_id','')::uuid, coalesce((ln->>'planned_qty')::numeric, 0), (ln->>'actual_qty')::numeric, it.unit, nullif(ln->>'remarks',''));
    n := n + 1;
  end loop;
  perform _p_audit('consumption', r.id, r.cons_no, 'Created', null, r.status, u, jsonb_build_object('lines', n));
  return to_jsonb(r);
end $$;

create or replace function prod_cons_approve(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; l prod_consumption_items%rowtype; bal numeric; n int := 0;
begin
  select * into r from prod_consumptions where id = p_id for update; if not found then raise exception 'Consumption not found'; end if;
  if r.status = 'Approved' then raise exception 'Consumption % is already approved — stock was not deducted again', r.cons_no; end if;
  if r.status <> 'Pending Approval' then raise exception 'Consumption % is % and cannot be approved', r.cons_no, r.status; end if;
  for l in select * from prod_consumption_items where cons_id = p_id order by created_at, id loop
    if l.source_tank_id is not null then
      bal := _p_tank_out(l.source_tank_id, l.item_id, l.actual_qty);
      perform _p_ledger('CONSUMPTION', 'CONS', r.id, r.cons_no, 'tank', l.source_tank_id, l.item_id, 'OUT', l.actual_qty, bal, p_user, 'Raw material consumed');
      n := n + 1;
    end if;
  end loop;
  update prod_consumptions set status = 'Approved', approved_by = p_user, approved_at = now() where id = p_id returning * into r;
  perform _p_audit('consumption', r.id, r.cons_no, case when n = 0 then 'Approved' else 'Approved — stock deducted' end, 'Pending Approval', 'Approved', p_user, jsonb_build_object('tank_lines', n));
  return to_jsonb(r);
end $$;

create or replace function prod_cons_reject(p_id uuid, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; old text;
begin
  select * into r from prod_consumptions where id = p_id for update; if not found then raise exception 'Consumption not found'; end if;
  old := r.status;
  if old = 'Rejected' then return to_jsonb(r); end if;
  if old <> 'Pending Approval' then raise exception 'Consumption % is % and cannot be rejected', r.cons_no, old; end if;
  update prod_consumptions set status = 'Rejected', approved_by = p_user, approved_at = now(), reject_reason = p_reason where id = p_id returning * into r;
  perform _p_audit('consumption', r.id, r.cons_no, 'Rejected', old, 'Rejected', p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(r);
end $$;

-- existing Production accounts get the two new pages (new installs get them from the starter data below)
update prod_users set pages = pages || ',orders,consumption'
 where pages <> 'all' and role <> 'Operator' and pages not like '%orders%';
update prod_users set pages = pages || ',orders'
 where pages <> 'all' and role = 'Operator' and pages not like '%orders%';

-- ================================================================
--  STARTER DATA  (Production's own — nothing is copied from Store)
-- ================================================================
insert into prod_categories(id, name, color, is_final, sort_order) values
  ('RAW',  'Raw Material',     '#2563eb', false, 10),
  ('PACK', 'Packing Material', '#f97316', false, 20),
  ('UTIL', 'Utility',          '#d97706', false, 30),
  ('FIN',  'Final Products',   '#16a34a', true,  40)
on conflict (id) do nothing;

-- default logins (CHANGE THESE PASSWORDS in Users after the first sign-in)
insert into prod_users(username, name, password_hash, role, pages, can_approve)
select v.u, v.n, crypt(v.p, gen_salt('bf')), v.r, v.pg, v.a
from (values
  ('admin',    'Production Admin',   'admin123', 'Super Admin', 'all', true),
  ('pmanager', 'Production Manager', 'pm123',    'Manager',     'dashboard,tanks,runs,orders,consumption,fill,receipts,dispatch,stock,approvals,reports,fillreports,masters', true),
  ('poperator','Production Operator','po123',    'Operator',    'dashboard,tanks,runs,orders,fill,stock', false)
) v(u, n, p, r, pg, a)
where not exists (select 1 from prod_users);


-- ================================================================
--  SOLOPOS Production app - QDPCC operations modules (run once, safe to re-run)
--  Stores the Production app's records: master items & stock, daily production,
--  consumption, filling, dispatch, GRV, NSF transfers, utility, HDPE drums,
--  LABSA transfers and the stock ledger.  Touches prod_* tables ONLY.
-- ================================================================
create table if not exists prod_ops_records (
  coll        text        not null,
  id          text        not null,
  data        jsonb       not null,
  updated_by  text,
  updated_at  timestamptz not null default now(),
  primary key (coll, id)
);
create index if not exists idx_prod_ops_coll on prod_ops_records(coll);

alter table prod_ops_records enable row level security;
drop policy if exists allow_anon_all on prod_ops_records;
create policy allow_anon_all on prod_ops_records for all to anon using (true) with check (true);

-- one atomic batch of changes: {"user":"..","upserts":[{"coll":"..","id":"..","data":{..}}],"deletes":[{"coll":"..","id":".."}]}
create or replace function prod_ops_apply(p jsonb) returns jsonb language plpgsql as $$
declare u jsonb; d jsonb; n_up int := 0; n_del int := 0;
begin
  for u in select * from jsonb_array_elements(coalesce(p->'upserts','[]'::jsonb)) loop
    insert into prod_ops_records(coll, id, data, updated_by, updated_at)
    values (u->>'coll', u->>'id', u->'data', p->>'user', now())
    on conflict (coll, id) do update set data = excluded.data, updated_by = excluded.updated_by, updated_at = now();
    n_up := n_up + 1;
  end loop;
  for d in select * from jsonb_array_elements(coalesce(p->'deletes','[]'::jsonb)) loop
    delete from prod_ops_records where coll = d->>'coll' and id = d->>'id';
    n_del := n_del + 1;
  end loop;
  return jsonb_build_object('upserted', n_up, 'deleted', n_del);
end $$;

grant all on prod_ops_records to anon;
grant execute on function prod_ops_apply(jsonb) to anon;

notify pgrst, 'reload schema';

-- ================================================================
--  ISOLATION CHECK  (both counts must be 0)
-- ================================================================
select 'foreign keys between Production and Store' as check_name, count(*) as violations
from pg_constraint c
join pg_class a on a.oid = c.conrelid  join pg_namespace na on na.oid = a.relnamespace and na.nspname = 'public'
join pg_class b on b.oid = c.confrelid join pg_namespace nb on nb.oid = b.relnamespace and nb.nspname = 'public'
where c.contype = 'f' and ((a.relname like 'prod\_%' and b.relname not like 'prod\_%') or (a.relname not like 'prod\_%' and b.relname like 'prod\_%'))
union all
select 'Production functions that mention a Store table', count(*)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where (p.proname like 'prod\_%' or p.proname like '\_p\_%')
  and (p.prosrc ~* '\m(from|join|into|update|delete\s+from|references)\s+(public\.)?(items|stock|warehouses|users|categories|purchases|purchase_items|gin_vouchers|gin_items|stock_transfers|production_orders|racks|suppliers|settings|voucher_sequences)\M'
        or p.prosrc ~* '\mnext_voucher_no\M');
