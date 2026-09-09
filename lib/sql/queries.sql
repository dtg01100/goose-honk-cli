-- Reference queries describing the public `goose session list --format json`
-- shape that honk consumes. The fields below are the documented
-- `--format json` output keys; honk does not depend on any private
-- storage schema (no reads from the goose SQLite sessions database,
-- no assumptions about the messages table).
--
-- This file is documentation only — none of the queries here are
-- executed at runtime. It exists so anyone reading the source can
-- see the data shape honk is built against, and so a future goose
-- release that changes the storage layer is clearly decoupled from
-- honk's behavior.

-- Sessions matching a substring of name/id/working_dir, newest first.
-- Search term is bound by the host script via shell-side quoting; do NOT
-- concatenate untrusted input here.
.name: recent sessions by name/id/working_dir
SELECT
    s.id,
    s.name,
    s.working_dir,
    strftime('%Y-%m-%dT%H:%M:%SZ', s.created_at)  AS created_at,
    strftime('%Y-%m-%dT%H:%M:%SZ', s.updated_at)  AS updated_at,
    s.accumulated_total_tokens,
    s.accumulated_cost,
    s.archived_at IS NOT NULL AS archived
FROM sessions AS s
ORDER BY datetime(s.updated_at) DESC
LIMIT 200;
