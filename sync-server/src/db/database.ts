import { Pool, type PoolClient, type QueryResultRow } from "pg";

import type { DatabaseConfig } from "../config.js";

export type ReadinessStatus = "up" | "down" | "unknown";

export interface DatabaseReadiness {
  readonly ready: boolean;
  readonly database: ReadinessStatus;
  readonly pgvector: ReadinessStatus;
  readonly pgvectorVersion?: string;
  readonly latencyMs: number;
}

export interface DatabaseResult<Row extends QueryResultRow = QueryResultRow> {
  readonly rows: readonly Row[];
  readonly rowCount: number;
}

export interface Queryable {
  query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>>;
}

export interface Database extends Queryable {
  checkReadiness(): Promise<DatabaseReadiness>;
  transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result>;
  close(): Promise<void>;
}

interface ReadinessRow extends QueryResultRow {
  readonly pgvector_version: string | null;
}

export interface DatabasePool {
  query(config: {
    readonly text: string;
    readonly query_timeout: number;
  }): Promise<{ readonly rows: QueryResultRow[] }>;
  execute?<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>>;
  transaction?<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result>;
  end(): Promise<void>;
}

const READINESS_QUERY = `
  SELECT (
    SELECT extversion
    FROM pg_catalog.pg_extension
    WHERE extname = 'vector'
  ) AS pgvector_version
`;

export class PostgresDatabase implements Database {
  private closed = false;

  constructor(
    private readonly pool: DatabasePool,
    private readonly readinessTimeoutMs: number,
  ) {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    const startedAt = performance.now();

    try {
      const result = await this.pool.query({
        text: READINESS_QUERY,
        query_timeout: this.readinessTimeoutMs,
      });
      const row = result.rows[0] as ReadinessRow | undefined;
      const pgvectorVersion = row?.pgvector_version ?? undefined;

      return {
        ready: pgvectorVersion !== undefined,
        database: "up",
        pgvector: pgvectorVersion === undefined ? "down" : "up",
        ...(pgvectorVersion === undefined ? {} : { pgvectorVersion }),
        latencyMs: elapsedMilliseconds(startedAt),
      };
    } catch {
      return {
        ready: false,
        database: "down",
        pgvector: "unknown",
        latencyMs: elapsedMilliseconds(startedAt),
      };
    }
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    if (this.closed) {
      throw new Error("Database is closed");
    }
    if (this.pool.execute === undefined) {
      throw new Error("This database adapter does not support application queries");
    }

    return this.pool.execute<Row>(text, values);
  }

  async transaction<Result>(
    work: (client: Queryable) => Promise<Result>,
  ): Promise<Result> {
    if (this.closed) {
      throw new Error("Database is closed");
    }
    if (this.pool.transaction === undefined) {
      throw new Error("This database adapter does not support transactions");
    }

    return this.pool.transaction(work);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }

    this.closed = true;
    await this.pool.end();
  }
}

function elapsedMilliseconds(startedAt: number): number {
  return Math.max(0, Math.round((performance.now() - startedAt) * 100) / 100);
}

export function createPostgresDatabase(config: DatabaseConfig): PostgresDatabase {
  const pool = new Pool({
    connectionString: config.url,
    max: config.poolMax,
    connectionTimeoutMillis: config.connectionTimeoutMs,
    idleTimeoutMillis: config.idleTimeoutMs,
    statement_timeout: config.statementTimeoutMs,
    lock_timeout: config.lockTimeoutMs,
    idle_in_transaction_session_timeout: config.idleInTransactionSessionTimeoutMs,
    application_name: "exeligmos-sync-server",
  });

  return new PostgresDatabase(
    {
      query: async (queryConfig) => pool.query<ReadinessRow>(queryConfig),
      execute: async <Row extends QueryResultRow = QueryResultRow>(
        text: string,
        values?: readonly unknown[],
      ) => databaseResult(await pool.query<Row>(text, values === undefined ? [] : [...values])),
      transaction: async <Result>(
        work: (client: Queryable) => Promise<Result>,
      ): Promise<Result> => withTransaction(pool, work),
      end: async () => pool.end(),
    },
    config.readinessTimeoutMs,
  );
}

async function withTransaction<Result>(
  pool: Pool,
  work: (client: Queryable) => Promise<Result>,
): Promise<Result> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await work(queryableClient(client));
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await rollback(client);
    throw error;
  } finally {
    client.release();
  }
}

function queryableClient(client: PoolClient): Queryable {
  return {
    query: async <Row extends QueryResultRow = QueryResultRow>(
      text: string,
      values?: readonly unknown[],
    ) => databaseResult(
      await client.query<Row>(text, values === undefined ? [] : [...values]),
    ),
  };
}

function databaseResult<Row extends QueryResultRow>(result: {
  readonly rows: Row[];
  readonly rowCount: number | null;
}): DatabaseResult<Row> {
  return {
    rows: result.rows,
    rowCount: result.rowCount ?? result.rows.length,
  };
}

async function rollback(client: PoolClient): Promise<void> {
  try {
    await client.query("ROLLBACK");
  } catch {
    // Preserve the original transaction error. The pool will discard a broken
    // connection when it is released.
  }
}
