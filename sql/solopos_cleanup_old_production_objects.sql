-- ================================================================
--  OPTIONAL CLEAN-UP — only if you ran the OLD solopos_fill_tank_production.sql
--
--  That earlier version put Tanks / Fills / Tank Production inside the Store
--  database and linked them to Store items and stock.  The new Production app
--  does NOT use any of it.  This script removes those old, now-unused objects
--  so nothing links Store and Production any more.
--
--  !!  DESTRUCTIVE: it permanently deletes any tank, fill and tank-production
--  !!  data you created with the OLD version.  Nothing is copied to the new
--  !!  Production app.  Skip this script if you want to keep that data for
--  !!  reference — the apps ignore it either way.
--  Store data (items, stock, vouchers) is NOT touched, except dropping the
--  old tank link column on production_orders.
-- ================================================================
alter table if exists production_orders drop column if exists tank_id;

drop table if exists tank_productions cascade;
drop table if exists fills            cascade;
drop table if exists stock_ledger     cascade;
drop table if exists module_audit_log cascade;
drop table if exists tanks            cascade;
drop table if exists app_config       cascade;

drop function if exists tank_create(jsonb), tank_adjust(uuid, numeric, uuid, text, text),
  fill_create(jsonb), fill_set_status(uuid, text, text, text), fill_complete(uuid, text),
  tprod_create(jsonb), tprod_start(uuid, text), tprod_complete(uuid, jsonb), tprod_cancel(uuid, text, text),
  _tank_usable(uuid, uuid), _tank_out(uuid, uuid, numeric), _tank_in(uuid, uuid, numeric),
  _store_move(uuid, uuid, numeric), _item_in_store(uuid, uuid), _same_product(uuid, uuid),
  _available(text, uuid, uuid), _ledger(text, text, uuid, text, text, uuid, uuid, text, text, text, numeric, numeric, text, text),
  _audit(text, uuid, text, text, text, text, text, jsonb);

notify pgrst, 'reload schema';
