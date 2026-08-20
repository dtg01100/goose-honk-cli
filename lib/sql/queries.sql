-- Reusable SQL fragments used by honk.
-- These are read via `sqlite3 ... <<EOF` style, not by Postgres/Python.

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

-- Last N messages for a session, oldest-first within the window so the
-- preview pane reads top-down as a conversation tail.
.last_messages
SELECT
    m.role,
    m.content_json,
    m.created_timestamp
FROM messages AS m
WHERE m.session_id = :session_id
ORDER BY m.created_timestamp DESC, m.id DESC
LIMIT :limit;

-- Plain-text extract of a message's user-visible body.
-- content_json is an array of typed parts: {type:"text",text:"…"} or
-- {type:"thinking",thinking:"…"} or {type:"toolRequest",…} etc. We collapse
-- all text/thinking parts to plain text; tool calls and results are surfaced
-- as `[tool:<name>]` placeholders so the preview stays readable.
.message_text
WITH parts(role, text) AS (
    SELECT
        m.role,
        coalesce(
            (SELECT group_concat(
                CASE json_extract(value, '$.type')
                    WHEN 'text'      THEN json_extract(value, '$.text')
                    WHEN 'thinking'  THEN '(thinking) ' || json_extract(value, '$.thinking')
                    WHEN 'toolRequest'    THEN '[tool:' ||
                        coalesce(json_extract(value, '$.name'), '?') || ']'
                    WHEN 'toolResponse'   THEN '[tool-result]'
                    WHEN 'toolConfirmationRequest' THEN '[tool-confirm]'
                    WHEN 'image'     THEN '[image]'
                    WHEN 'resource'  THEN '[resource]'
                    ELSE '[other]'
                END, char(10))
             FROM json_each(m.content_json)),
            ''
        ) AS text
    FROM messages AS m
    WHERE m.session_id = :session_id
)
SELECT role, text FROM parts WHERE length(text) > 0;
