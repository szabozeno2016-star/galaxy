#!/usr/bin/env bash
# Combines supabase/src/*.sql into the single file you paste into Supabase.
set -euo pipefail
cd "$(dirname "$0")/.."
out=supabase/schema.sql
{
  echo "-- GENERATED from supabase/src/*.sql by scripts/build-schema.sh — edit those files, not this one."
  for f in supabase/src/*.sql; do
    echo
    echo "-- ---- $(basename "$f") ----"
    cat "$f"
  done
} > "$out"
echo "Wrote $out ($(wc -l < "$out") lines)"
