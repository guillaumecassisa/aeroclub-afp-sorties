-- ===================== Vérification finale =====================
notify pgrst, 'reload schema';
select
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'aircraft' and column_name = 'available') = 1
    and exists (select 1 from pg_proc where proname = 'set_aircraft_availability')
    and exists (select 1 from pg_proc where proname = 'set_maintenance')
    and exists (select 1 from pg_proc where proname = 'review_outing')
    and to_regclass('public.announcements') is not null
    and to_regclass('public.bar_products') is not null
    and to_regclass('public.pilot_weights') is not null
    and to_regclass('public.aircraft_documents') is not null
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'kind')
    and exists (select 1 from information_schema.columns where table_name = 'bar_products' and column_name = 'category')
    and exists (select 1 from pg_proc where proname = 'set_function')
    and exists (select 1 from pg_proc where proname = 'event_mail_recipients')
    and exists (select 1 from pg_proc where proname = 'can_manage_docs')
    and exists (select 1 from pg_proc where proname = 'anonymize_member')
    and to_regclass('public.audit_log') is not null
    and to_regclass('public.club_links') is not null
    and to_regclass('public.aircraft_mb') is not null
    and exists (select 1 from information_schema.columns where table_name = 'aircraft_mb' and column_name = 'mzfw')
    and to_regclass('public.airfield_tips') is not null
    and exists (select 1 from pg_proc where proname = 'move_crew')
    and exists (select 1 from information_schema.columns where table_name = 'outings' and column_name = 'referent_instructor_id')
    and to_regclass('public.shop_orders') is not null
    and to_regclass('public.flight_shares') is not null
    and exists (select 1 from pg_proc where proname = 'set_shop_order_status')
    and exists (select 1 from pg_proc where proname = 'quiz_today')
    and to_regclass('public.rex_reports') is not null
    and exists (select 1 from pg_proc where proname = '_can_fly_in')
    and exists (select 1 from pg_proc where proname = 'set_guest_count')
    and exists (select 1 from pg_proc where proname = 'place_waitlisted')
    and exists (select 1 from pg_proc where proname = 'admin_export')
    and to_regclass('public._seeds') is not null
    and exists (select 1 from pg_policies where policyname = 'quiz_questions_teach_update')
    and exists (select 1 from pg_proc where proname = 'quiz_today_set')
    and exists (select 1 from public._seeds where name = 'quiz-flotte-35')
    and exists (select 1 from public._seeds where name = 'quiz-reglement-42')
    and to_regclass('public.shop_stock') is not null and to_regclass('public.quiz_daily_set') is not null and exists (select 1 from pg_trigger where tgname = 'on_auth_user_deleted') and to_regclass('public.shop_settings') is not null and exists (select 1 from pg_proc where proname = 'set_outing_poster') and exists (select 1 from pg_proc where proname = 'bar_members') and (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'outings' and column_name = 'departure_at') = 'YES'
  as "TOUT EST A JOUR",
  (select count(*) from public.profiles) as membres,
  (select string_agg(registration, ', ' order by registration) from public.aircraft) as avions,
  (select count(*) from public.aircraft_mb where empty_mass is not null and jsonb_array_length(envelope) >= 3) as "avions M&C prêts";
