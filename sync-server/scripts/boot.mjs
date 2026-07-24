import { existsSync } from "node:fs";
import { once } from "node:events";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

const ROOT = resolve(import.meta.dirname, "..");
const NPM = process.platform === "win32" ? "npm.cmd" : "npm";
const isDevelopment = process.argv.includes("--dev");
const postgresUser = process.env.POSTGRES_USER?.trim() || "exeligmos";
const postgresDatabase = process.env.POSTGRES_DB?.trim() || "exeligmos";

function sleep(milliseconds) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

function command(program, argumentsList, options = {}) {
  const { timeoutMs = 30_000, inheritOutput = false } = options;

  return new Promise((resolveCommand, rejectCommand) => {
    const child = spawn(program, argumentsList, {
      cwd: ROOT,
      env: process.env,
      stdio: inheritOutput ? "inherit" : ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;

    if (!inheritOutput) {
      child.stdout?.on("data", (chunk) => {
        stdout += chunk;
      });
      child.stderr?.on("data", (chunk) => {
        stderr += chunk;
      });
    }

    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);
    timeout.unref();

    child.once("error", (error) => {
      clearTimeout(timeout);
      rejectCommand(error);
    });
    child.once("close", (code, signal) => {
      clearTimeout(timeout);
      if (code === 0) {
        resolveCommand({ stdout, stderr });
        return;
      }

      const output = [stdout.trim(), stderr.trim()].filter(Boolean).join("\n");
      const reason = timedOut
        ? `timed out after ${timeoutMs} ms`
        : `exited with ${signal === null ? `code ${code}` : `signal ${signal}`}`;
      rejectCommand(new Error(`${program} ${argumentsList.join(" ")} ${reason}${output ? `:\n${output}` : ""}`));
    });
  });
}

async function waitForDocker() {
  try {
    await command("docker", ["info", "--format", "{{.ServerVersion}}"], { timeoutMs: 5_000 });
    return;
  } catch (initialError) {
    if (process.platform !== "darwin") {
      throw new Error(
        `Docker is not ready. Start Docker and retry. (${messageOf(initialError)})`,
      );
    }
  }

  console.log("Docker is not ready; asking Docker Desktop to launch…");
  await command("open", ["-gja", "Docker"], { timeoutMs: 10_000 });

  const deadline = Date.now() + 90_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      await command("docker", ["info", "--format", "{{.ServerVersion}}"], { timeoutMs: 5_000 });
      return;
    } catch (error) {
      lastError = error;
      await sleep(2_000);
    }
  }

  throw new Error(
    `Docker Desktop did not become ready within 90 seconds. Restart Docker Desktop, then retry. (${messageOf(lastError)})`,
  );
}

async function waitForPostgres() {
  console.log("Starting PostgreSQL…");
  await command("docker", ["compose", "up", "-d", "postgres"], {
    timeoutMs: 45_000,
    inheritOutput: true,
  });

  const deadline = Date.now() + 90_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      await command(
        "docker",
        ["compose", "exec", "-T", "postgres", "pg_isready", "-U", postgresUser, "-d", postgresDatabase],
        { timeoutMs: 5_000 },
      );
      console.log("PostgreSQL is ready.");
      return;
    } catch (error) {
      lastError = error;
      await sleep(1_000);
    }
  }

  throw new Error(
    `PostgreSQL did not become ready within 90 seconds. Inspect it with \`docker compose logs postgres\`. (${messageOf(lastError)})`,
  );
}

function serverHealthUrl() {
  const configuredHost = process.env.HOST?.trim();
  const host =
    configuredHost === undefined || configuredHost === "" || configuredHost === "0.0.0.0" || configuredHost === "::"
      ? "127.0.0.1"
      : configuredHost;
  const port = process.env.PORT?.trim() || "8788";
  return `http://${host.includes(":") ? `[${host}]` : host}:${port}/health/ready`;
}

async function waitForServer(child) {
  const url = serverHealthUrl();
  const deadline = Date.now() + 30_000;
  let lastError;

  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Server exited before becoming ready (code ${child.exitCode}).`);
    }

    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(1_500) });
      if (response.ok) {
        const health = await response.json();
        if (health.status === "ready") {
          console.log(`Server is ready at ${url}`);
          return;
        }
      }
      lastError = new Error(`health endpoint returned HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }

    await sleep(500);
  }

  throw new Error(`Server did not become ready within 30 seconds. (${messageOf(lastError)})`);
}

async function startServer() {
  const script = isDevelopment ? "dev:v2" : "start:v2";
  const child = spawn(NPM, ["run", script], {
    cwd: ROOT,
    env: process.env,
    stdio: "inherit",
  });
  const exit = once(child, "exit");
  const forwardSignal = (signal) => {
    child.kill(signal);
  };
  process.once("SIGINT", forwardSignal);
  process.once("SIGTERM", forwardSignal);

  try {
    await waitForServer(child);
    const [code, signal] = await exit;
    return code ?? (signal === null ? 1 : 0);
  } finally {
    process.removeListener("SIGINT", forwardSignal);
    process.removeListener("SIGTERM", forwardSignal);
  }
}

function messageOf(error) {
  return error instanceof Error ? error.message : String(error);
}

async function main() {
  if (!existsSync(resolve(ROOT, ".env"))) {
    throw new Error("Missing .env. Copy .env.example to .env and configure it before booting.");
  }
  if (!isDevelopment && !existsSync(resolve(ROOT, "dist/server.js"))) {
    throw new Error("Missing compiled server. Run `npm run build`, or use `npm run boot:dev` during development.");
  }

  await waitForDocker();
  await waitForPostgres();

  console.log("Applying database migrations…");
  await command(NPM, ["run", isDevelopment ? "db:migrate" : "db:migrate:prod"], {
    timeoutMs: 120_000,
    inheritOutput: true,
  });

  console.log(`Starting ${isDevelopment ? "development" : "compiled"} server…`);
  process.exitCode = await startServer();
}

void main().catch((error) => {
  console.error(`Boot failed: ${messageOf(error)}`);
  process.exitCode = 1;
});
