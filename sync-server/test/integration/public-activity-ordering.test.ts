import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import { runMigrations } from "../../src/db/migrate.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "deferred public activity publication serializes multi-resource commits without early lock inversion",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });

    const setup = new Client({ connectionString: databaseUrl });
    const first = new Client({ connectionString: databaseUrl });
    const second = new Client({ connectionString: databaseUrl });
    await Promise.all([setup.connect(), first.connect(), second.connect()]);

    const userId = randomUUID();
    const competingUserId = randomUUID();
    try {
      const login = `ordering-${randomUUID()}`;
      const competingLogin = `ordering-${randomUUID()}`;
      await setup.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES
           ($1, $2, 'Ordering test', 'test'),
           ($3, $4, 'Competing test', 'test')`,
        [userId, login, competingUserId, competingLogin],
      );
      const device = await setup.query<{ id: string }>(
        `INSERT INTO devices (user_id, name, kind)
         VALUES ($1, 'Ordering agent', 'agent')
         RETURNING id`,
        [userId],
      );
      const deviceId = required(device.rows[0]?.id);
      const competingDevice = await setup.query<{ id: string }>(
        `INSERT INTO devices (user_id, name, kind)
         VALUES ($1, 'Competing agent', 'agent')
         RETURNING id`,
        [competingUserId],
      );
      const competingDeviceId = required(competingDevice.rows[0]?.id);
      const record = await setup.query<{ id: string }>(
        `INSERT INTO records (user_id, device_id, event_at, public_payload)
         VALUES ($1, $2, now(), '{"text":"record"}'::jsonb)
         RETURNING id`,
        [userId, deviceId],
      );
      const firstEvent = await setup.query<{ id: string }>(
        `INSERT INTO events (user_id, device_id, starts_at, label, type)
         VALUES ($1, $2, now(), 'First event', 1)
         RETURNING id`,
        [userId, deviceId],
      );
      const competingEvent = await setup.query<{ id: string }>(
        `INSERT INTO events (user_id, device_id, starts_at, label, type)
         VALUES ($1, $2, now(), 'Competing event', 2)
         RETURNING id`,
        [competingUserId, competingDeviceId],
      );
      const recordId = required(record.rows[0]?.id);
      const firstEventId = required(firstEvent.rows[0]?.id);
      const secondEventId = required(competingEvent.rows[0]?.id);

      await Promise.all([first.query("BEGIN"), second.query("BEGIN")]);
      await Promise.all([
        first.query("SET LOCAL lock_timeout = '2s'"),
        second.query("SET LOCAL lock_timeout = '2s'"),
      ]);

      // Both writers must finish their resource statements before either one
      // commits. An immediate row trigger taking the global activity lock
      // would block the second statement here while it still holds row locks.
      await first.query(
        "UPDATE records SET metadata = '{\"writer\":\"first\"}'::jsonb WHERE id = $1",
        [recordId],
      );
      await first.query(
        "UPDATE events SET metadata = '{\"writer\":\"first\"}'::jsonb WHERE id = $1",
        [firstEventId],
      );
      await second.query(
        "UPDATE events SET metadata = '{\"writer\":\"second\"}'::jsonb WHERE id = $1",
        [secondEventId],
      );

      await Promise.all([first.query("COMMIT"), second.query("COMMIT")]);

      const activity = await setup.query<{
        sequence: string;
        resource_id: string;
      }>(
        `SELECT sequence::text, resource_id
         FROM public_activity
         WHERE resource_type IN ('record', 'event')
           AND resource_id = ANY($1::uuid[])
           AND revision = 2
         ORDER BY sequence`,
        [[recordId, firstEventId, secondEventId]],
      );
      assert.equal(activity.rows.length, 3);
      const firstTransactionSequences = activity.rows
        .filter((row) => row.resource_id === recordId || row.resource_id === firstEventId)
        .map((row) => BigInt(row.sequence))
        .sort((left, right) => left < right ? -1 : left > right ? 1 : 0);
      assert.equal(firstTransactionSequences.length, 2);
      assert.equal(
        requiredBigInt(firstTransactionSequences[1]) - requiredBigInt(firstTransactionSequences[0]),
        1n,
        "one transaction must hold the publisher gate across all deferred resource events",
      );

      const triggers = await setup.query<{
        tgname: string;
        tgdeferrable: boolean;
        tginitdeferred: boolean;
      }>(
        `SELECT tgname, tgdeferrable, tginitdeferred
         FROM pg_trigger
         WHERE tgname IN (
           'records_public_activity_after_write',
           'events_public_activity_after_write',
           'users_public_activity_after_write'
         )
         ORDER BY tgname`,
      );
      assert.deepEqual(triggers.rows, [
        {
          tgname: "events_public_activity_after_write",
          tgdeferrable: true,
          tginitdeferred: true,
        },
        {
          tgname: "records_public_activity_after_write",
          tgdeferrable: true,
          tginitdeferred: true,
        },
        {
          tgname: "users_public_activity_after_write",
          tgdeferrable: true,
          tginitdeferred: true,
        },
      ]);
    } finally {
      await Promise.allSettled([first.query("ROLLBACK"), second.query("ROLLBACK")]);
      await setup.query(
        "DELETE FROM users WHERE id = ANY($1::uuid[])",
        [[userId, competingUserId]],
      );
      await Promise.all([setup.end(), first.end(), second.end()]);
    }
  },
);

function required(value: string | undefined): string {
  if (value === undefined) {
    throw new Error("Expected database identifier");
  }
  return value;
}

function requiredBigInt(value: bigint | undefined): bigint {
  if (value === undefined) {
    throw new Error("Expected activity sequence");
  }
  return value;
}
