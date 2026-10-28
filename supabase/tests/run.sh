#!/usr/bin/env bash
# SQL test harness. Runs ONLY against a throwaway PostgreSQL server (local sandbox or CI container).
# Never point it at a real or shared database: it drops and recreates the database pd_test and the app roles.
#
# Connection: standard libpq variables for a SUPERUSER of the throwaway server
#   PGHOST (default localhost), PGPORT (default 5432), PGUSER (default postgres), PGPASSWORD.
#
# Steps: reset -> stub Supabase (auth.users, API roles) -> migrations as pd_migrator (CREATEROLE, no
# SUPERUSER, no BYPASSRLS, like Supabase's postgres) -> seed twice -> checks scripts -> test files.
set -euo pipefail

cd "$(dirname "$0")/../.."

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
DB=pd_test

case "$PGHOST" in
  *supabase* | *pooler*)
    echo "refusing to run: PGHOST=$PGHOST looks like a real Supabase host" >&2
    exit 2
    ;;
esac

psql_su() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psql_migrator() { PGOPTIONS="-c role=pd_migrator" psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

echo "== reset throwaway database $DB on $PGHOST:$PGPORT"
psql_su -d postgres <<'SQL'
SET client_min_messages = warning;
DROP DATABASE IF EXISTS pd_test WITH (FORCE);
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy',
                           'app_maintenance', 'pd_migrator', 'anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END $$;
CREATE ROLE pd_migrator NOLOGIN CREATEROLE NOSUPERUSER NOBYPASSRLS;
CREATE DATABASE pd_test;
GRANT CREATE ON DATABASE pd_test TO pd_migrator;
SQL

echo "== stub Supabase objects"
psql_su -d "$DB" -f supabase/tests/_setup_superuser.sql

echo "== apply migrations as pd_migrator"
for f in supabase/migrations/*.sql; do
  echo "   $f"
  psql_migrator --single-transaction -f "$f"
done

echo "== apply seed (twice: must be idempotent)"
for f in supabase/seed/*.sql; do
  echo "   $f"
  psql_migrator --single-transaction -f "$f"
  psql_migrator --single-transaction -f "$f"
done

failures=0

echo "== checks scripts"
for f in supabase/checks/*.sql; do
  [ -e "$f" ] || continue
  echo "   $f"
  out="$(psql_migrator -At -F ' | ' -f "$f")"
  echo "$out" | sed 's/^/     /'
  if echo "$out" | grep -q '| FAIL$'; then
    failures=$((failures + 1))
  fi
done

echo "== SQL tests"
psql_su -d "$DB" -f supabase/tests/_harness.sql
passed=0
failed=0
for f in supabase/tests/[0-9][0-9]_*.sql; do
  echo "-- $f"
  set +e
  out="$(psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" 2>&1)"
  status=$?
  set -e
  echo "$out" | grep -E 'NOTICE:  (not )?ok ' | sed -E 's/^.*NOTICE:  //'
  p=$(echo "$out" | grep -cE 'NOTICE:  ok ' || true)
  q=$(echo "$out" | grep -cE 'NOTICE:  not ok ' || true)
  passed=$((passed + p))
  failed=$((failed + q))
  if [ "$status" -ne 0 ]; then
    echo "$out" | grep -E 'ERROR|FATAL' | sed 's/^/   /'
    echo "   file aborted with psql exit status $status"
    failures=$((failures + 1))
  fi
done

echo "== SQL tests: $passed passed, $failed failed; checks/aborts with problems: $failures"
if [ "$failed" -ne 0 ] || [ "$failures" -ne 0 ]; then
  exit 1
fi
