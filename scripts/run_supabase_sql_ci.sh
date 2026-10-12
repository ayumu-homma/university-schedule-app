#!/usr/bin/env bash
set -euo pipefail

# This entry point belongs to a fresh, disposable GitHub-hosted CI runner.
if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]]; then
  echo "This SQL runner requires a disposable GitHub-hosted Actions environment." >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--privileges-only" ) ]]; then
  echo "Usage: run_supabase_sql_ci.sh [--privileges-only]" >&2
  exit 1
fi

project_id="$(awk -F '"' '/^project_id[[:space:]]*=/{print $2; exit}' supabase/config.toml)"
if [[ -z "$project_id" ]]; then
  echo "Missing disposable Supabase project id." >&2
  exit 1
fi
mapfile -t db_containers < <(docker ps \
  --filter "label=com.supabase.cli.project=$project_id" \
  --filter 'name=supabase_db_' --format '{{.Names}}')
if [[ "${#db_containers[@]}" -ne 1 ]]; then
  echo "Expected exactly one project-scoped disposable CI database." >&2
  exit 1
fi

if [[ "${1:-}" == "--privileges-only" ]]; then
  python3 - <<'PY'
import pathlib
import tomllib

config = tomllib.loads(pathlib.Path("supabase/config.toml").read_text())
assert "private" not in config["api"]["schemas"], "Private schema must not be exposed"
PY
  docker exec -i "${db_containers[0]}" \
    psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet -U postgres -d postgres \
    < scripts/ci_migration_privileges.sql
  exit 0
fi

commit_test="supabase/tests/course_template_duplicate_candidates_auth_commit.sql"
tap_tests=()
for path in supabase/tests/*.sql; do
  if [[ "$path" != "$commit_test" ]]; then
    tap_tests+=("$path")
  fi
done
supabase test db --local "${tap_tests[@]}"

# This test must really COMMIT. Its DO assertions use ON_ERROR_STOP rather
# than TAP output; keep it out of pg_prove discovery without skipping it.
docker exec -i "${db_containers[0]}" \
  psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet -U postgres -d postgres \
  < "$commit_test"
