-- ================================================================
--  NO LONGER NEEDED
--  Production now lives only in the Production app (see solopos_production_app.sql).
--  The Store app no longer reads or writes production_orders, production_raw_materials
--  or production_outputs, so the run-time columns this file used to add are not used.
--  Running it is harmless but pointless.
-- ================================================================
select 1 as nothing_to_do;
