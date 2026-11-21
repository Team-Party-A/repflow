\set ON_ERROR_STOP on
\if :{?bench_apply}
\else
  \set bench_apply off
\endif

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';

-- Keep the account locked during verification and cleanup, including late writes.
SELECT count(*) = 1 AS bench_matched
FROM (
    SELECT 1 FROM public.users
    WHERE user_id = :'bench_user_id'::uuid
      AND username = :'bench_username'
      AND username ~ '^rfbench_[0-9a-f]{20}$'
      AND created_at BETWEEN now() - interval '24 hours' AND now()
    FOR UPDATE
) AS identity
\gset

\if :bench_matched
  SELECT
      (SELECT count(*) FROM public.sessions WHERE user_id = :'bench_user_id'::uuid) AS sessions,
      (SELECT count(*) FROM public.workouts WHERE user_id = :'bench_user_id'::uuid) AS workouts,
      (SELECT count(*) FROM public.workout_sets AS s JOIN public.workouts AS w USING (workout_id)
       WHERE w.user_id = :'bench_user_id'::uuid) AS sets
  \gset bench_
  SELECT :bench_sessions <= 160 AND :bench_workouts <= 180 AND :bench_sets <= 540 AS bench_bounded
  \gset
  \if :bench_bounded
    \echo Verified test account. Sessions :bench_sessions Workouts :bench_workouts Sets :bench_sets
    \if :bench_apply
      DELETE FROM public.workout_sets AS s USING public.workouts AS w
      WHERE s.workout_id = w.workout_id AND w.user_id = :'bench_user_id'::uuid;
      DELETE FROM public.workouts WHERE user_id = :'bench_user_id'::uuid;
      DELETE FROM public.sessions WHERE user_id = :'bench_user_id'::uuid;
      DELETE FROM public.users
      WHERE user_id = :'bench_user_id'::uuid AND username = :'bench_username';
    \endif
  \else
    DO $$ BEGIN RAISE EXCEPTION 'test account exceeds the expected run size'; END $$;
  \endif
\else
  DO $$ BEGIN RAISE EXCEPTION 'fresh test account identity did not match'; END $$;
\endif
COMMIT;

\if :bench_apply
  SELECT NOT EXISTS (SELECT FROM public.users WHERE user_id = :'bench_user_id'::uuid OR username = :'bench_username')
     AND NOT EXISTS (SELECT FROM public.sessions WHERE user_id = :'bench_user_id'::uuid)
     AND NOT EXISTS (SELECT FROM public.workouts WHERE user_id = :'bench_user_id'::uuid) AS bench_empty
  \gset
  \if :bench_empty
    \echo Verified no remaining rows.
  \else
    DO $$ BEGIN RAISE EXCEPTION 'test account cleanup could not be confirmed'; END $$;
  \endif
\endif
