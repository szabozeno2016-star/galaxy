#!/usr/bin/env bash
# Runs the database tests against a throwaway local Postgres.
# Usage: scripts/test-db.sh            (needs Postgres 15+ binaries and bun)
set -euo pipefail
cd "$(dirname "$0")/.."
PGBIN=${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}
DATA=${PGDATA_DIR:-/home/claude/pg/data}
export PGHOST=/tmp PGPORT=${PGPORT:-54329} PGUSER=postgres

if ! "$PGBIN/pg_isready" -q; then
  if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA" && chown postgres "$(dirname "$DATA")" "$DATA" 2>/dev/null || true
    su postgres -c "$PGBIN/initdb -D $DATA -U postgres --auth=trust" >/dev/null
  fi
  su postgres -c "$PGBIN/pg_ctl -D $DATA -o '-p $PGPORT -k /tmp' -l $DATA/../log.txt start" >/dev/null
  for _ in $(seq 1 30); do "$PGBIN/pg_isready" -q && break; sleep 0.3; done
fi

./scripts/build-schema.sh >/dev/null
"$PGBIN/dropdb" --if-exists galaxy_test
"$PGBIN/createdb" galaxy_test
"$PGBIN/psql" -q -v ON_ERROR_STOP=1 -d galaxy_test -f tests/db/supabase_stubs.sql
"$PGBIN/psql" -q -v ON_ERROR_STOP=1 -d galaxy_test -f supabase/schema.sql
# Applying twice proves the schema can be re-run to upgrade a live project
"$PGBIN/psql" -q -v ON_ERROR_STOP=1 -d galaxy_test -f supabase/schema.sql
echo "schema applied twice OK"
DATABASE_URL="postgres://postgres@localhost:$PGPORT/galaxy_test?host=/tmp" bun test tests/db "$@"
