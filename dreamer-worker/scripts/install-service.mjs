#!/usr/bin/env node

import { execFile } from "node:child_process";
import { mkdir, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";

const run = promisify(execFile);
const label = "app.exeligmos.dreamer-worker";

export async function installWorkerService() {
  if (process.platform !== "darwin") {
    throw new Error("Automatic Dreamer startup is currently supported on macOS.");
  }
  const root = path.resolve(import.meta.dirname, "..");
  const launchAgents = path.join(os.homedir(), "Library", "LaunchAgents");
  const logRoot = path.join(os.homedir(), "Library", "Logs", "Fractonica");
  const target = path.join(launchAgents, `${label}.plist`);
  await mkdir(launchAgents, { recursive: true });
  await mkdir(logRoot, { recursive: true });
  const temporary = `${target}.${process.pid}.tmp`;
  await writeFile(
    temporary,
    plist({
      root,
      stdout: path.join(logRoot, "dreamer-worker.log"),
      stderr: path.join(logRoot, "dreamer-worker.error.log"),
    }),
    { encoding: "utf8", mode: 0o600 },
  );
  await rename(temporary, target);
  const domain = `gui/${process.getuid()}`;
  await run("launchctl", ["bootout", domain, target]).catch(() => undefined);
  await run("launchctl", ["bootstrap", domain, target]);
  await run("launchctl", ["kickstart", "-k", `${domain}/${label}`]);
  console.log(`Installed and started ${label}.`);
}

function plist({ root, stdout, stderr }) {
  const args = [
    process.execPath,
    "--env-file-if-exists=.env",
    "src/cli.mjs",
    "--config",
    "dreamer.config.json",
  ];
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key><array>${args.map((value) => `<string>${xml(value)}</string>`).join("")}</array>
  <key>WorkingDirectory</key><string>${xml(root)}</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin")}</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${xml(stdout)}</string>
  <key>StandardErrorPath</key><string>${xml(stderr)}</string>
</dict></plist>
`;
}

function xml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

if (path.resolve(process.argv[1] ?? "") === path.resolve(import.meta.filename)) {
  await installWorkerService();
}
