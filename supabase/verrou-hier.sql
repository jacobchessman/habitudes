-- Le passé reste figé, sauf hier: on peut encore cocher/décocher la veille (habitudes faites juste avant de dormir).
-- Remplace les règles « cocher » et « décocher » de verrou-passe.sql (aujourd'hui seulement → aujourd'hui ou hier).
drop policy if exists "cocher" on public.checks;
create policy "cocher" on public.checks for insert to authenticated with check (
  user_id = auth.uid()
  and day between public.aujourdhui() - 1 and public.aujourdhui()
  and exists (select 1 from public.habits h where h.id = habit_id and h.user_id = auth.uid() and h.archived_at is null)
);

drop policy if exists "décocher" on public.checks;
create policy "décocher" on public.checks for delete to authenticated using (
  user_id = auth.uid() and day between public.aujourdhui() - 1 and public.aujourdhui()
);

select 'ok' as resultat, public.aujourdhui() - 1 as hier_encore_modifiable;
