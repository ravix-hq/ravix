/**
 * One-off: the SQLite file from the Kubernetes deployment into Render's
 * Postgres.
 *
 *   DATABASE_URL=postgres://… bun scripts/sqlite-to-postgres.ts /path/to/ravix.sqlite
 *
 * Creates the schema (the same `Db.open` the server runs), then copies every
 * table in foreign-key order inside one transaction, so a failure part-way
 * leaves the target as it was. Refuses a target that already has users in
 * it. The only column names that differ are the prompt queue's, which were
 * camelCase in SQLite and are snake_case here; everything else is copied by
 * name. Identity columns keep their SQLite values so nothing that referenced
 * a sequence number changes meaning.
 */
import { Database } from "bun:sqlite";
import { Db } from "../server/db";
import { openSql } from "../server/sql";

const [file] = process.argv.slice(2);
const url = process.env.DATABASE_URL;
if (!file || !url) throw new Error("Usage: DATABASE_URL=postgres://… bun scripts/sqlite-to-postgres.ts ravix.sqlite");

/** Tables in the order their foreign keys allow, with any column renames. */
const TABLES: { name: string; columns?: Record<string, string>; identity?: string; order?: string }[] = [
  { name: "users" },
  { name: "sessions" },
  { name: "oauth_states" },
  { name: "projects" },
  { name: "tracks" },
  { name: "prompt_queue", columns: { trackId: "track_id", userId: "user_id", authorLogin: "author_login", createdAt: "created_at" }, identity: "sequence", order: "sequence" },
  { name: "track_members" },
  { name: "track_invites" },
  { name: "track_links" },
  { name: "project_members" },
  { name: "project_invites" },
  { name: "project_links" },
  { name: "track_reads" },
  { name: "preview_defaults" },
  { name: "previews" },
  { name: "preview_grants" },
  { name: "preview_agent_grants" },
  { name: "browser_sessions" },
  { name: "browser_checkpoints" },
  { name: "browser_agent_grants" },
  { name: "native_experiment_services" },
  { name: "native_runner_pairings" },
  { name: "native_runners" },
  { name: "native_targets" },
  { name: "native_requests", order: "rowid" },
];

const source = new Database(file, { readonly: true });
const sql = await openSql({ url });
const db = await Db.open(sql);
const [{ n }] = await sql.query<{ n: number }>("SELECT COUNT(*) AS n FROM users");
if (n > 0) throw new Error(`The target already has ${n} users; refusing to copy over it.`);

await sql.transaction(async () => {
  for (const table of TABLES) {
    const exists = source.query<{ n: number }, [string]>("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = ?").get(table.name)?.n;
    if (!exists) { console.log(`${table.name}: not in the source, skipped`); continue; }
    const rows = source.query<Record<string, unknown>, []>(`SELECT * FROM ${table.name}${table.order ? ` ORDER BY ${table.order}` : ""}`).all();
    for (const row of rows) {
      const columns = Object.keys(row).map(c => table.columns?.[c] ?? c);
      const values = Object.values(row);
      const placeholders = values.map((_, i) => `$${i + 1}`).join(", ");
      await sql.run(
        `INSERT INTO ${table.name} (${columns.join(", ")})${table.identity ? " OVERRIDING SYSTEM VALUE" : ""} VALUES (${placeholders})`,
        values,
      );
    }
    if (table.identity && rows.length) {
      await sql.query(`SELECT setval(pg_get_serial_sequence('${table.name}', '${table.identity}'), (SELECT MAX(${table.identity}) FROM ${table.name}))`);
    }
    console.log(`${table.name}: ${rows.length} rows`);
  }
});

await db.close();
source.close();
console.log("done");
