-- =====================================================================
--  NOUVEAU CLUB : retire les données d'exemple reprises de l'AFPA
--  (avions et masse & centrage, carte du bar, liens utiles, bons plans,
--  articles du shop, questions du quiz sur LFMA, la flotte et le règlement intérieur de l'AFPA). À exécuter UNE FOIS, juste après
--  installation-complete.sql, sur une base neuve.
--  Ensuite : ajoutez vos avions dans « Flotte (maintenance) », votre carte
--  dans « Bar → Trésorerie », vos liens dans « Liens utiles »…
-- =====================================================================
do $$ begin
  if exists (select 1 from public.outings) or exists (select 1 from public.bar_consumptions)
     or exists (select 1 from public.shop_orders) then
    raise exception 'Cette base contient déjà des données du club : script réservé à une installation neuve.';
  end if;
end $$;

delete from public.aircraft_documents;
delete from public.aircraft_mb;
delete from public.aircraft;
delete from public.bar_products;
delete from public.club_links;
delete from public.airfield_tips;
delete from public.shop_items;
-- Questions du quiz propres à l'AFPA (terrain LFMA, avions de la flotte, règlement intérieur) : à réécrire pour votre club
delete from public.quiz_questions q
 where (q.category in ('lfma', 'flotte') or q.explanation like '%(Règlement intérieur AFPA%')
   and not exists (select 1 from public.quiz_answers a where a.question_id = q.id);
update public.club_info set association_name = 'Mon aéroclub', address = null, registration_number = null,
  publication_director = null, contact_email = null, contact_phone = null, updated_at = now()
 where id = 1;

select 'Données d''exemple retirées : renseignez maintenant votre club (Gestion des droits → Informations du club).' as "OK";
