#!/usr/bin/env bash
# SQL test harness. Runs ONLY against a throwaway PostgreSQL server (local sandbox or CI container).
# Never point it at a real or shared database: it drops and recreates the database pd_test and the app roles.
#
# Connection: standard libpq variables for a SUPERUSER of the throwaway server
#   PGHOST (default localhost), PGPORT (default 5432), PGUSER (default postgres), PGPASSWORD.
#
# Steps: reset -> stub Supabase (auth.users, API roles) -> migrations as pd_migrator -> seed twice -> checks
# scripts -> test files -> operator scripts.
#
# pd_migrator stands in for Supabase's postgres (staging, PostgreSQL 17.11, probed 29 Oct 2026: not SUPERUSER,
# CREATEROLE, BYPASSRLS). It logs in as itself, like postgres in the SQL editor. Migrations are applied while it is
# still NOBYPASSRLS (stricter than Supabase: a migration must never depend on bypassing RLS); it then gets BYPASSRLS
# for everything the founder runs afterwards (seed, checks scripts, operator scripts), so a check that reads rows
# without SET ROLE to an application role sees everything here too.
set -euo pipefail

cd "$(dirname "$0")/../.."

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
DB=pd_test
# Staging's major version (PostgreSQL 17.11, founder 29 Oct 2026). CI uses the postgres:17.11 image.
PG_MAJOR=17
# Throwaway password for the throwaway pd_migrator login; never a real credential.
MIGRATOR_PASSWORD=pd_migrator

case "$PGHOST" in
  *supabase* | *pooler*)
    echo "refusing to run: PGHOST=$PGHOST looks like a real Supabase host" >&2
    exit 2
    ;;
esac

psql_su() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psql_migrator() { PGUSER=pd_migrator PGPASSWORD="$MIGRATOR_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
export DB MIGRATOR_PASSWORD

major="$(psql_su -d postgres -At -c "SELECT current_setting('server_version_num')::int / 10000")"
if [ "$major" != "$PG_MAJOR" ]; then
  echo "refusing to run: the server is PostgreSQL $major, staging runs $PG_MAJOR (e.g. docker run postgres:17.11)" >&2
  exit 2
fi

echo "== reset throwaway database $DB on $PGHOST:$PGPORT"
psql_su -d postgres <<'SQL'
SET client_min_messages = warning;
DROP DATABASE IF EXISTS pd_test WITH (FORCE);
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['app_runtime', 'app_domain', 'app_authz', 'app_bootstrap', 'app_freebusy',
                           'app_maintenance', 'app_operator', 'pd_migrator', 'anon', 'authenticated',
                           'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END $$;
CREATE ROLE pd_migrator LOGIN PASSWORD 'pd_migrator' CREATEROLE NOSUPERUSER NOBYPASSRLS;
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

echo "== pd_migrator gets BYPASSRLS, as postgres has on Supabase (seed, checks and operator scripts run with it)"
psql_su -d postgres -c "ALTER ROLE pd_migrator BYPASSRLS"

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
  # A file can abort before its first assertion: an empty grep must not end the run (set -e, pipefail).
  echo "$out" | grep -E 'NOTICE:  (not )?ok ' | sed -E 's/^.*NOTICE:  //' || true
  p=$(echo "$out" | grep -cE 'NOTICE:  ok ' || true)
  q=$(echo "$out" | grep -cE 'NOTICE:  not ok ' || true)
  passed=$((passed + p))
  failed=$((failed + q))
  if [ "$status" -ne 0 ]; then
    echo "$out" | grep -E 'ERROR|FATAL' | sed 's/^/   /' || true
    echo "   file aborted with psql exit status $status"
    failures=$((failures + 1))
  fi
done

echo "== SQL tests: $passed passed, $failed failed; checks/aborts with problems: $failures"
if [ "$failed" -ne 0 ] || [ "$failures" -ne 0 ]; then
  exit 1
fi
