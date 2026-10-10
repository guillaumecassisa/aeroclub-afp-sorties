-- =====================================================================
--  Mise à jour n°17 : annonces publiées par toute personne ayant une
--  fonction (admin, instructeur, CA, trésorier, secrétaire, resp.
--  maintenance). Les simples membres les lisent seulement.
-- =====================================================================
drop policy if exists announcements_insert on public.announcements;
create policy announcements_insert on public.announcements for insert to authenticated
  with check (public.can_organize());
drop policy if exists announcements_delete on public.announcements;
create policy announcements_delete on public.announcements for delete to authenticated
  using (public.can_organize());

notify pgrst, 'reload schema';
