-- =====================================================================
-- Finanças By Anderson — Esquema, RLS e funções (Supabase / PostgreSQL)
-- ---------------------------------------------------------------------
-- Rode este arquivo inteiro no SQL Editor do seu projeto Supabase.
-- Seguro para rodar novamente (usa IF NOT EXISTS / OR REPLACE).
-- =====================================================================

create extension if not exists pgcrypto;

-- =====================================================================
-- TABELAS
-- =====================================================================

-- Perfil mínimo de cada usuário (espelha auth.users)
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  display_name text,
  updated_at   timestamptz not null default now()
);

-- Documento financeiro de cada usuário (os dados do app).
-- Cada usuário possui UMA linha. A proteção é feita por LINHA via RLS,
-- nunca por filtro de JavaScript. O dono de cada registro é a chave
-- (user_id), então não há como "trocar o dono" para acessar o alheio.
create table if not exists public.user_data (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  doc        jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Um "share" = o vínculo entre no máximo 2 contas.
create table if not exists public.shares (
  id         uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Membros de um share. user_id como PRIMÁRIA garante que cada usuário
-- participa de NO MÁXIMO 1 compartilhamento ao mesmo tempo.
create table if not exists public.share_members (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  share_id  uuid not null references public.shares(id) on delete cascade,
  joined_at timestamptz not null default now()
);
create index if not exists share_members_share_idx on public.share_members(share_id);

-- Convites de compartilhamento (com validade e estado).
create table if not exists public.invites (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  invitee_email text not null,
  invitee_id    uuid references auth.users(id) on delete set null,
  status        text not null default 'pending'
                check (status in ('pending','accepted','cancelled','expired')),
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,
  expires_at    timestamptz not null default (now() + interval '7 days')
);
create index if not exists invites_invitee_idx on public.invites(invitee_id);
create index if not exists invites_email_idx   on public.invites(lower(invitee_email));
create index if not exists invites_sender_idx  on public.invites(sender_id);
-- No máximo 1 convite PENDENTE por remetente:
create unique index if not exists invites_one_pending_per_sender
  on public.invites(sender_id) where (status = 'pending');

-- =====================================================================
-- FUNÇÕES AUXILIARES (SECURITY DEFINER para evitar recursão de RLS)
-- =====================================================================

create or replace function public.my_share_id()
returns uuid language sql stable security definer set search_path = public as $$
  select share_id from public.share_members where user_id = auth.uid()
$$;

create or replace function public.my_partner_id()
returns uuid language sql stable security definer set search_path = public as $$
  select m.user_id from public.share_members m
  where m.share_id = public.my_share_id() and m.user_id <> auth.uid()
  limit 1
$$;

-- Garante no máximo 2 membros por share
create or replace function public.enforce_share_limit()
returns trigger language plpgsql as $$
declare n int;
begin
  select count(*) into n from public.share_members where share_id = new.share_id;
  if n >= 2 then
    raise exception 'Um compartilhamento permite no máximo 2 contas';
  end if;
  return new;
end $$;
drop trigger if exists trg_share_limit on public.share_members;
create trigger trg_share_limit before insert on public.share_members
  for each row execute function public.enforce_share_limit();

-- Cria perfil automaticamente quando um usuário se cadastra
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, email, display_name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Atualiza updated_at
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_touch_user_data on public.user_data;
create trigger trg_touch_user_data before update on public.user_data
  for each row execute function public.touch_updated_at();
drop trigger if exists trg_touch_profiles on public.profiles;
create trigger trg_touch_profiles before update on public.profiles
  for each row execute function public.touch_updated_at();

-- =====================================================================
-- ROW LEVEL SECURITY
-- =====================================================================

alter table public.profiles      enable row level security;
alter table public.user_data     enable row level security;
alter table public.shares        enable row level security;
alter table public.share_members enable row level security;
alter table public.invites       enable row level security;

-- profiles: leio o meu e o do meu parceiro; só edito o meu.
drop policy if exists profiles_sel on public.profiles;
create policy profiles_sel on public.profiles for select
  using (id = auth.uid() or id = public.my_partner_id());
drop policy if exists profiles_ins on public.profiles;
create policy profiles_ins on public.profiles for insert
  with check (id = auth.uid());
drop policy if exists profiles_upd on public.profiles;
create policy profiles_upd on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- user_data: leio o meu e o do parceiro; escrevo/apago APENAS o meu.
-- (as políticas de escrita exigem user_id = auth.uid(), logo é impossível
--  gravar na linha de outra pessoa ou forjar o dono de um registro.)
drop policy if exists ud_sel on public.user_data;
create policy ud_sel on public.user_data for select
  using (user_id = auth.uid() or user_id = public.my_partner_id());
drop policy if exists ud_ins on public.user_data;
create policy ud_ins on public.user_data for insert
  with check (user_id = auth.uid());
drop policy if exists ud_upd on public.user_data;
create policy ud_upd on public.user_data for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists ud_del on public.user_data;
create policy ud_del on public.user_data for delete
  using (user_id = auth.uid());

-- shares / share_members: somente leitura dos registros do meu share.
-- Toda mutação acontece via funções RPC (SECURITY DEFINER) abaixo,
-- portanto não há políticas de insert/update/delete para o cliente.
drop policy if exists shares_sel on public.shares;
create policy shares_sel on public.shares for select
  using (id = public.my_share_id());
drop policy if exists sm_sel on public.share_members;
create policy sm_sel on public.share_members for select
  using (share_id = public.my_share_id());

-- invites: vejo convites que enviei ou que são para mim.
drop policy if exists inv_sel on public.invites;
create policy inv_sel on public.invites for select
  using (sender_id = auth.uid()
         or invitee_id = auth.uid()
         or lower(invitee_email) = lower(coalesce(auth.email(), '')));

-- =====================================================================
-- RPCs DE COMPARTILHAMENTO (toda autorização é feita aqui, no banco)
-- =====================================================================

-- Enviar convite por e-mail (sem expor dados de terceiros).
create or replace function public.send_invite(p_email text)
returns json language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_target uuid; v_id uuid;
begin
  if v_me is null then raise exception 'Não autenticado'; end if;
  if p_email is null or length(trim(p_email)) = 0 then raise exception 'Informe um e-mail'; end if;
  if lower(trim(p_email)) = lower(coalesce(auth.email(),'')) then
    raise exception 'Você não pode convidar a si mesmo'; end if;
  if public.my_share_id() is not null then
    raise exception 'Você já está compartilhando com alguém'; end if;
  update public.invites set status='expired' where status='pending' and expires_at < now();
  if exists(select 1 from public.invites where sender_id = v_me and status='pending') then
    raise exception 'Você já tem um convite pendente'; end if;
  select id into v_target from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_target is not null and exists(select 1 from public.share_members where user_id = v_target) then
    raise exception 'Essa pessoa já está compartilhando com outra conta'; end if;
  insert into public.invites(sender_id, invitee_email, invitee_id)
    values (v_me, lower(trim(p_email)), v_target)
    returning id into v_id;
  return json_build_object('ok', true, 'id', v_id, 'found', (v_target is not null));
end $$;

-- Aceitar convite — atômico, com trava de linha e limite de 2 contas.
create or replace function public.accept_invite(p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_inv public.invites; v_share uuid;
begin
  if v_me is null then raise exception 'Não autenticado'; end if;
  select * into v_inv from public.invites where id = p_id for update; -- trava
  if not found then raise exception 'Convite não encontrado'; end if;
  if v_inv.status <> 'pending' then raise exception 'Convite indisponível'; end if;
  if v_inv.expires_at < now() then
    update public.invites set status='expired' where id = p_id;
    raise exception 'Convite expirado'; end if;
  if not (v_inv.invitee_id = v_me
          or lower(v_inv.invitee_email) = lower(coalesce(auth.email(),''))) then
    raise exception 'Este convite não é para você'; end if;
  if exists(select 1 from public.share_members where user_id = v_me) then
    raise exception 'Você já está compartilhando com alguém'; end if;
  if exists(select 1 from public.share_members where user_id = v_inv.sender_id) then
    update public.invites set status='cancelled' where id = p_id;
    raise exception 'O remetente já está compartilhando com outra conta'; end if;
  insert into public.shares(created_by) values (v_inv.sender_id) returning id into v_share;
  insert into public.share_members(user_id, share_id) values (v_inv.sender_id, v_share);
  insert into public.share_members(user_id, share_id) values (v_me, v_share);
  update public.invites set status='accepted', responded_at=now(), invitee_id=v_me where id = p_id;
  update public.invites set status='cancelled'
    where status='pending' and id <> p_id and sender_id in (v_me, v_inv.sender_id);
  return json_build_object('ok', true, 'share', v_share);
end $$;

-- Cancelar / recusar convite pendente (remetente ou destinatário).
create or replace function public.cancel_invite(p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_inv public.invites;
begin
  select * into v_inv from public.invites where id = p_id for update;
  if not found then raise exception 'Convite não encontrado'; end if;
  if not (v_inv.sender_id = v_me or v_inv.invitee_id = v_me
          or lower(v_inv.invitee_email) = lower(coalesce(auth.email(),''))) then
    raise exception 'Sem permissão'; end if;
  if v_inv.status = 'pending' then
    update public.invites set status='cancelled', responded_at=now() where id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;

-- Encerrar o compartilhamento (qualquer um dos dois) — revoga o acesso.
create or replace function public.end_share()
returns json language plpgsql security definer set search_path = public as $$
declare v_share uuid := public.my_share_id();
begin
  if v_share is null then raise exception 'Você não está compartilhando'; end if;
  delete from public.shares where id = v_share; -- cascade remove os membros
  return json_build_object('ok', true);
end $$;

-- Estado atual de compartilhamento (para a interface).
create or replace function public.my_share_state()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_partner uuid; v_pname text; v_pemail text;
        v_sent json; v_recv json;
begin
  v_partner := public.my_partner_id();
  if v_partner is not null then
    select display_name, email into v_pname, v_pemail from public.profiles where id = v_partner;
  end if;
  select json_agg(json_build_object('id', id, 'email', invitee_email, 'expires', expires_at))
    into v_sent from public.invites where sender_id = v_me and status='pending';
  select json_agg(json_build_object('id', i.id, 'from', p.display_name, 'email', i.invitee_email, 'expires', i.expires_at))
    into v_recv from public.invites i left join public.profiles p on p.id = i.sender_id
    where i.status='pending'
      and (i.invitee_id = v_me or lower(i.invitee_email) = lower(coalesce(auth.email(),'')));
  return json_build_object(
    'me', v_me,
    'partner', case when v_partner is null then null
                    else json_build_object('id', v_partner, 'name', v_pname, 'email', v_pemail) end,
    'sent', coalesce(v_sent, '[]'::json),
    'received', coalesce(v_recv, '[]'::json));
end $$;

-- Permissões de execução das RPCs
grant execute on function public.send_invite(text)  to authenticated;
grant execute on function public.accept_invite(uuid) to authenticated;
grant execute on function public.cancel_invite(uuid) to authenticated;
grant execute on function public.end_share()        to authenticated;
grant execute on function public.my_share_state()   to authenticated;

-- (Opcional) Realtime para refletir mudanças do parceiro ao vivo:
-- alter publication supabase_realtime add table public.user_data;
-- alter publication supabase_realtime add table public.share_members;
