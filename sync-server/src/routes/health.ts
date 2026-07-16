import type { FastifyInstance } from "fastify";

import type { Database, ReadinessStatus } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";

interface HealthRouteOptions {
  readonly database: Database;
}

interface ReadinessChecks {
  readonly database: ReadinessStatus;
  readonly pgvector: ReadinessStatus;
}

export async function registerHealthRoutes(
  app: FastifyInstance,
  options: HealthRouteOptions,
): Promise<void> {
  app.get(
    "/health/live",
    {
      schema: {
        response: {
          200: {
            type: "object",
            additionalProperties: false,
            required: ["status"],
            properties: {
              status: { const: "ok" },
            },
          },
        },
      },
    },
    async () => ({ status: "ok" as const }),
  );

  app.get("/health/ready", async (_request, reply) => {
    const result = await options.database.checkReadiness();
    const checks: ReadinessChecks = {
      database: result.database,
      pgvector: result.pgvector,
    };

    if (!result.ready) {
      reply.header("retry-after", "5");
      throw new HttpProblem({
        status: 503,
        title: "Service Unavailable",
        type: "urn:exeligmos:problem:not-ready",
        detail: "The service is not ready to accept traffic.",
        extensions: { checks },
      });
    }

    return {
      status: "ready" as const,
      checks,
    };
  });
}
