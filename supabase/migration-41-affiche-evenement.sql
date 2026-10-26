-- =====================================================================
--  Mise à jour n°41 : affiche (photo) des événements
--  L'organisateur d'un événement peut y joindre une affiche, montrée en haut de la
--  page de l'événement. Sans affiche, rien n'est affiché.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Adresse de l'affiche
alter table public.outings add column if not exists poster_url text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'outings_poster_url_check'
                   and conrelid = 'public.outings'::regclass) then
    alter table public.outings add constraint outings_poster_url_check
      check (poster_url is null or (length(poster_url) <= 500 and poster_url ~ '^https?://'));
  end if;
end $$;

-- Peut gérer l'affiche : les organisateurs du club, et l'organisateur de l'événement
create or replace function public._can_manage_outing_poster(p_outing uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_approved() and (
           public.can_organize()
           or exists (select 1 from public.outings o
                       where o.id = p_outing and o.instructor_id = auth.uid() and o.status <> 'cancelled'))
$$;
revoke execute on function public._can_manage_outing_poster(uuid) from public, anon;
grant execute on function public._can_manage_outing_poster(uuid) to authenticated;

-- 2. Enregistrer / retirer l'affiche (l'image doit être celle déposée pour cet événement)
create or replace function public.set_outing_poster(p_outing uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.outings where id = p_outing) then
    raise exception 'Événement introuvable.';
  end if;
  if not public._can_manage_outing_poster(p_outing) then
    raise exception 'Seul l''organisateur de l''événement peut changer son affiche.';
  end if;
  if p_url is not null and position('/storage/v1/object/public/documents/events/' || p_outing::text || '/' in p_url) = 0 then
    raise exception 'Affiche invalide.';
  end if;
  update public.outings set poster_url = p_url, updated_at = now() where id = p_outing;
end;
$$;
revoke execute on function public.set_outing_poster(uuid, text) from public, anon;
grant execute on function public.set_outing_poster(uuid, text) to authenticated;

-- 3. Fichiers : dossier events/<id de l'événement>/ du stockage « documents » (images, 5 Mo max)
drop policy if exists event_posters_insert on storage.objects;
create policy event_posters_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and name like 'events/%'
              and public._can_manage_outing_poster(nullif(split_part(name, '/', 2), '')::uuid));
drop policy if exists event_posters_delete on storage.objects;
create policy event_posters_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and name like 'events/%'
         and public._can_manage_outing_poster(nullif(split_part(name, '/', 2), '')::uuid));

-- 4. La page d'un événement renvoie son affiche
do $$
declare d text;
begin
  select pg_get_functiondef('public.get_outing(uuid)'::regprocedure) into d;
  if position('''poster_url''' in d) = 0 then
    d := regexp_replace(d, '''title'',(\s*)v_row\.title,', '''title'',\1v_row.title,' || E'\n    ''poster_url'', v_row.poster_url,');
    if position('''poster_url''' in d) = 0 then raise exception 'get_outing : emplacement introuvable'; end if;
    execute d;
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 41 OK' as resultat,
       exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'outings' and column_name = 'poster_url') as colonne_affiche;
