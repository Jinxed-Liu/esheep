create schema if not exists private;

revoke all on schema private from public, anon, authenticated;

create table private.farm_sheep_invariants (
    farm_id uuid not null,
    sheep_id uuid not null,
    sex text,
    is_breeding_ram boolean not null default false,
    deleted_at timestamptz,
    source_revision bigint not null,
    source_operation_id uuid not null,
    primary key (farm_id, sheep_id)
);

revoke all on table private.farm_sheep_invariants
    from public, anon, authenticated;

create or replace function private.apply_farm_sheep_invariant(
    p_farm_id uuid,
    p_entity_id uuid,
    p_operation_id uuid,
    p_revision bigint,
    p_payload jsonb,
    p_deleted_at timestamptz,
    p_validate boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_kind text := p_payload ->> 'kind';
    v_command jsonb;
    v_sheep_id uuid;
    v_dam_id uuid;
    v_sire_id uuid;
    v_active boolean;
    v_parent private.farm_sheep_invariants%rowtype;
begin
    -- Serialize the small invariant projection per farm. This closes the race
    -- between concurrent devices validating a parent and changing its status.
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(p_farm_id::text, 91521)
    );

    if v_kind = 'addSheep' then
        insert into private.farm_sheep_invariants (
            farm_id,
            sheep_id,
            sex,
            is_breeding_ram,
            deleted_at,
            source_revision,
            source_operation_id
        ) values (
            p_farm_id,
            p_entity_id,
            p_payload #>> '{strings,sex}',
            coalesce((p_payload #>> '{integers,isBreedingRam}')::integer, 0) = 1,
            p_deleted_at,
            p_revision,
            p_operation_id
        )
        on conflict (farm_id, sheep_id) do update set
            sex = excluded.sex,
            is_breeding_ram = excluded.is_breeding_ram,
            deleted_at = excluded.deleted_at,
            source_revision = excluded.source_revision,
            source_operation_id = excluded.source_operation_id
        where excluded.source_revision >=
            private.farm_sheep_invariants.source_revision;
        return;
    end if;

    if v_kind = 'updateSheepProfile' then
        v_sheep_id := coalesce(
            (p_payload #>> '{identifiers,sheepID}')::uuid,
            p_entity_id
        );
        update private.farm_sheep_invariants
        set sex = p_payload #>> '{strings,sex}',
            is_breeding_ram = case
                when p_payload #>> '{strings,sex}' = 'ram'
                    then is_breeding_ram
                else false
            end,
            deleted_at = p_deleted_at,
            source_revision = p_revision,
            source_operation_id = p_operation_id
        where farm_id = p_farm_id
          and sheep_id = v_sheep_id
          and source_revision <= p_revision;
        return;
    end if;

    if v_kind = 'care' and
       p_payload #> '{careCommand,setBreedingRam}' is not null then
        v_command := p_payload #> '{careCommand,setBreedingRam}';
        v_sheep_id := (v_command ->> 'sheepID')::uuid;
        v_active := (v_command ->> 'isBreedingRam')::boolean;

        select * into v_parent
        from private.farm_sheep_invariants
        where farm_id = p_farm_id and sheep_id = v_sheep_id;

        if p_validate and v_active and (
            not found or v_parent.deleted_at is not null or v_parent.sex <> 'ram'
        ) then
            raise exception using
                errcode = '40001',
                message = 'breeding_ram_qualification_mismatch',
                detail = 'A breeding ram must be an active sheep with sex=ram.';
        end if;

        if found then
            update private.farm_sheep_invariants
            set is_breeding_ram = v_active,
                source_revision = p_revision,
                source_operation_id = p_operation_id
            where farm_id = p_farm_id
              and sheep_id = v_sheep_id
              and source_revision <= p_revision;
        end if;
        return;
    end if;

    if v_kind = 'care' and
       p_payload #> '{careCommand,updateSheepPedigree,_0}' is not null then
        v_command := p_payload #> '{careCommand,updateSheepPedigree,_0}';
        v_dam_id := nullif(v_command ->> 'damID', '')::uuid;
        v_sire_id := nullif(v_command ->> 'sireID', '')::uuid;

        if p_validate and v_dam_id is not null then
            select * into v_parent
            from private.farm_sheep_invariants
            where farm_id = p_farm_id and sheep_id = v_dam_id;
            if not found or v_parent.deleted_at is not null or
               v_parent.sex <> 'ewe' then
                raise exception using
                    errcode = '40001',
                    message = 'pedigree_parent_qualification_mismatch',
                    detail = 'The dam must be an active ewe.';
            end if;
        end if;

        if p_validate and v_sire_id is not null then
            select * into v_parent
            from private.farm_sheep_invariants
            where farm_id = p_farm_id and sheep_id = v_sire_id;
            if not found or v_parent.deleted_at is not null or
               v_parent.sex <> 'ram' or not v_parent.is_breeding_ram then
                raise exception using
                    errcode = '40001',
                    message = 'pedigree_parent_qualification_mismatch',
                    detail = 'The sire must be an active breeding ram.';
            end if;
        end if;
        return;
    end if;

    if v_kind = 'tombstoneEntity' and
       p_payload #>> '{strings,entityType}' = 'sheep' then
        v_sheep_id := coalesce(
            (p_payload #>> '{identifiers,entityID}')::uuid,
            p_entity_id
        );
        update private.farm_sheep_invariants
        set deleted_at = coalesce(p_deleted_at, pg_catalog.now()),
            is_breeding_ram = false,
            source_revision = p_revision,
            source_operation_id = p_operation_id
        where farm_id = p_farm_id
          and sheep_id = v_sheep_id
          and source_revision <= p_revision;
    end if;
end;
$$;

create or replace function private.enforce_farm_sheep_invariant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_payload jsonb;
begin
    begin
        v_payload := pg_catalog.convert_from(
            pg_catalog.decode(new.payload_base64, 'base64'),
            'utf8'
        )::jsonb;
    exception when others then
        raise exception using
            errcode = '22023',
            message = 'invalid_farm_operation_payload';
    end;

    perform private.apply_farm_sheep_invariant(
        new.farm_id,
        new.entity_id,
        new.operation_id,
        new.revision,
        v_payload,
        new.deleted_at,
        true
    );
    return new;
end;
$$;

revoke all on function private.apply_farm_sheep_invariant(
    uuid, uuid, uuid, bigint, jsonb, timestamptz, boolean
) from public, anon, authenticated;
revoke all on function private.enforce_farm_sheep_invariant()
    from public, anon, authenticated;

-- Replay immutable history without validating it. This deliberately preserves
-- legacy invalid operations for audit while reconstructing the parent state
-- against which every future operation is validated.
do $$
declare
    v_operation record;
begin
    for v_operation in
        select
            farm_id,
            entity_id,
            operation_id,
            revision,
            pg_catalog.convert_from(
                pg_catalog.decode(payload_base64, 'base64'),
                'utf8'
            )::jsonb as payload,
            deleted_at
        from public.farm_operations
        order by farm_id, revision, server_received_at, operation_id
    loop
        perform private.apply_farm_sheep_invariant(
            v_operation.farm_id,
            v_operation.entity_id,
            v_operation.operation_id,
            v_operation.revision,
            v_operation.payload,
            v_operation.deleted_at,
            false
        );
    end loop;
end;
$$;

drop trigger if exists enforce_farm_sheep_invariant
    on public.farm_operations;
create trigger enforce_farm_sheep_invariant
after insert on public.farm_operations
for each row execute function private.enforce_farm_sheep_invariant();
