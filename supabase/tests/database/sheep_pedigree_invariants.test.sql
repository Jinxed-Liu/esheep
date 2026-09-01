begin;

create extension if not exists pgtap with schema extensions;
select plan(11);

select set_config('esheep.test.invariant_farm', gen_random_uuid()::text, false);
select set_config('esheep.test.invariant_ewe', gen_random_uuid()::text, false);
select set_config('esheep.test.invariant_ram', gen_random_uuid()::text, false);
select set_config('esheep.test.invariant_child', gen_random_uuid()::text, false);

select has_table(
  'private',
  'farm_sheep_invariants',
  'private sheep invariant projection exists'
);

select ok(
  exists (
    select 1
    from pg_catalog.pg_trigger trigger_record
    join pg_catalog.pg_class table_record
      on table_record.oid = trigger_record.tgrelid
    join pg_catalog.pg_namespace schema_record
      on schema_record.oid = table_record.relnamespace
    where schema_record.nspname = 'public'
      and table_record.relname = 'farm_operations'
      and trigger_record.tgname = 'enforce_farm_sheep_invariant'
      and not trigger_record.tgisinternal
  ),
  'farm operation inserts enforce the sheep invariant'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'private.apply_farm_sheep_invariant(uuid,uuid,uuid,bigint,jsonb,timestamptz,boolean)',
    'EXECUTE'
  ),
  'authenticated clients cannot call the private projector'
);

select private.apply_farm_sheep_invariant(
  current_setting('esheep.test.invariant_farm')::uuid,
  current_setting('esheep.test.invariant_ewe')::uuid,
  gen_random_uuid(),
  1,
  jsonb_build_object(
    'kind', 'addSheep',
    'strings', jsonb_build_object('sex', 'ewe')
  ),
  null,
  false
);
select private.apply_farm_sheep_invariant(
  current_setting('esheep.test.invariant_farm')::uuid,
  current_setting('esheep.test.invariant_ram')::uuid,
  gen_random_uuid(),
  2,
  jsonb_build_object(
    'kind', 'addSheep',
    'strings', jsonb_build_object('sex', 'ram')
  ),
  null,
  false
);

select throws_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 3,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'updateSheepPedigree', jsonb_build_object(
            '_0', jsonb_build_object(
              'sheepID', %L,
              'damID', %L,
              'sireID', %L
            )
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_child'),
    current_setting('esheep.test.invariant_child'),
    current_setting('esheep.test.invariant_ewe'),
    current_setting('esheep.test.invariant_ram')
  ),
  '40001',
  'pedigree_parent_qualification_mismatch',
  'a ram that is not marked for breeding cannot be selected as sire'
);

select lives_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 4,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'setSheepPurpose', jsonb_build_object(
            'sheepID', %L,
            'purpose', '种公羊',
            'reason', '数据库测试'
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_ram'),
    current_setting('esheep.test.invariant_ram')
  ),
  'the unified purpose command can qualify an active male sheep as a breeding ram'
);

select lives_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 5,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'updateSheepPedigree', jsonb_build_object(
            '_0', jsonb_build_object(
              'sheepID', %L,
              'damID', %L,
              'sireID', %L
            )
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_child'),
    current_setting('esheep.test.invariant_child'),
    current_setting('esheep.test.invariant_ewe'),
    current_setting('esheep.test.invariant_ram')
  ),
  'pedigree accepts an active ewe and an active breeding ram'
);

select throws_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 6,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'setSheepPurpose', jsonb_build_object(
            'sheepID', %L,
            'purpose', '种公羊',
            'reason', '数据库测试'
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_ewe'),
    current_setting('esheep.test.invariant_ewe')
  ),
  '40001',
  'breeding_ram_qualification_mismatch',
  'the unified purpose command cannot qualify an ewe as a breeding ram'
);

select is(
  (
    select count(*)::integer
    from private.farm_sheep_invariants
    where farm_id = current_setting('esheep.test.invariant_farm')::uuid
      and sheep_id = current_setting('esheep.test.invariant_ram')::uuid
      and sex = 'ram'
      and is_breeding_ram
      and deleted_at is null
  ),
  1,
  'the guard projection retains the authoritative breeding-ram state'
);

select lives_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 7,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'setSheepPurpose', jsonb_build_object(
            'sheepID', %L,
            'purpose', '育成羊',
            'reason', '数据库测试'
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_ram'),
    current_setting('esheep.test.invariant_ram')
  ),
  'changing away from breeding-ram purpose clears the qualification'
);

select is(
  (
    select is_breeding_ram
    from private.farm_sheep_invariants
    where farm_id = current_setting('esheep.test.invariant_farm')::uuid
      and sheep_id = current_setting('esheep.test.invariant_ram')::uuid
  ),
  false,
  'the guard projection records the cleared breeding-ram qualification'
);

select lives_ok(
  format(
    $$select private.apply_farm_sheep_invariant(
      %L::uuid, %L::uuid, gen_random_uuid(), 8,
      jsonb_build_object(
        'kind', 'care',
        'careCommand', jsonb_build_object(
          'setBreedingRam', jsonb_build_object(
            'sheepID', %L,
            'isBreedingRam', true
          )
        )
      ), null, true
    )$$,
    current_setting('esheep.test.invariant_farm'),
    current_setting('esheep.test.invariant_ram'),
    current_setting('esheep.test.invariant_ram')
  ),
  'legacy queued breeding-ram commands remain replayable'
);

select * from finish();
rollback;
