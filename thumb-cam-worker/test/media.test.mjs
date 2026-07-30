import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { promisify } from "node:util";

import {
  cleanupVisualArtifacts,
  parseSymmetry,
  symmetryOutputMode,
  transcribeAudio,
  transformVisual,
} from "../src/media.mjs";
import { uuidFromHex } from "../src/server-client.mjs";

const run = promisify(execFile);

test("uses the paired rotated mirror operation", () => {
  assert.equal(symmetryOutputMode(), "paired_rotated");
  assert.deepEqual(parseSymmetry("paired_rotated"), {
    sides: ["positive", "negative"],
    rotateDegrees: 90,
  });
});

test("derives a stable RFC 4122 UUID from a content fingerprint", () => {
  const uuid = uuidFromHex("a".repeat(64));
  assert.equal(uuid, "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa");
  assert.match(
    uuid,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
});

test("uses the MLX Whisper bridge and removes output after transcription", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-whisper-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const executable = path.join(root, "fake-python.mjs");
  const audioPath = path.join(root, "capture.wav");
  await writeFile(audioPath, "audio");
  await writeFile(
    executable,
    [
      "#!/usr/bin/env node",
      'const fs = await import("node:fs");',
      "const output = process.argv[5];",
      'fs.writeFileSync(output, JSON.stringify({ text: "  hello world  " }));',
    ].join("\n"),
  );
  await chmod(executable, 0o755);

  const text = await transcribeAudio(
    {
      workRoot: root,
      pythonExecutable: executable,
      whisperModel: "mlx-community/test-whisper-mlx",
    },
    audioPath,
  );

  assert.equal(text, "hello world");
  assert.deepEqual(await readdir(path.join(root, "transcripts")), []);

  await writeFile(
    executable,
    [
      "#!/usr/bin/env node",
      'const fs = await import("node:fs");',
      "const output = process.argv[5];",
      'fs.writeFileSync(output, "{}");',
      "process.exitCode = 1;",
    ].join("\n"),
  );
  await assert.rejects(
    transcribeAudio(
      {
        workRoot: root,
        pythonExecutable: executable,
        whisperModel: "mlx-community/test-whisper-mlx",
      },
      audioPath,
    ),
    /MLX Whisper failed/,
  );
  assert.deepEqual(await readdir(path.join(root, "transcripts")), []);
});

test("cleans generated visual files after success and ffmpeg failure", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-visual-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const first = path.join(root, "processed.jpg");
  const second = path.join(root, "preview.jpg");
  await writeFile(first, "one");
  await writeFile(second, "two");
  await cleanupVisualArtifacts({ temporaryPaths: [first, second] });
  await assert.rejects(access(first));
  await assert.rejects(access(second));

  const failingFfmpeg = path.join(root, "failing-ffmpeg.mjs");
  await writeFile(
    failingFfmpeg,
    [
      "#!/usr/bin/env node",
      'const fs = await import("node:fs");',
      "const output = process.argv.at(-1);",
      'fs.mkdirSync((await import("node:path")).dirname(output), { recursive: true });',
      'fs.writeFileSync(output, "partial");',
      "process.exitCode = 1;",
    ].join("\n"),
  );
  await chmod(failingFfmpeg, 0o755);
  const source = path.join(root, "source.jpg");
  await writeFile(source, "photo");
  await assert.rejects(
    transformVisual(
      {
        ffmpegExecutable: failingFfmpeg,
        workRoot: root,
      },
      {
        absolutePath: source,
        kind: "photo",
        relativePath: "PHOTO/source.jpg",
        sourceKey: "a".repeat(64),
      },
      "paired_rotated",
    ),
  );
  const processedDirectory = path.join(root, "processed");
  await mkdir(processedDirectory, { recursive: true });
  assert.deepEqual(await readdir(processedDirectory), []);
});

test("creates two independent rotated square mirrors from a horizontal frame", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-paired-mirror-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const source = path.join(root, "source.jpg");
  await run("/opt/homebrew/bin/ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "testsrc=size=256x144",
    "-frames:v",
    "1",
    source,
  ]);

  const transformed = await transformVisual(
    {
      ffmpegExecutable: "/opt/homebrew/bin/ffmpeg",
      workRoot: root,
    },
    {
      absolutePath: source,
      kind: "photo",
      relativePath: "PHOTO/source.jpg",
      sourceKey: "b".repeat(64),
    },
    "paired_rotated",
  );

  assert.deepEqual(
    transformed.outputs.map((output) => output.fileName),
    [
      "source-symmetric-positive.jpg",
      "source-symmetric-negative.jpg",
    ],
  );
  for (const output of transformed.outputs) {
    const { stdout } = await run("/opt/homebrew/bin/ffprobe", [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height",
      "-of",
      "csv=p=0",
      output.absolutePath,
    ]);
    assert.equal(stdout.trim(), "256,256");
  }
});

test("hardware-encodes two independent square mirrors from a local video", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-video-mirror-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const source = path.join(root, "source.avi");
  await run("/opt/homebrew/bin/ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "testsrc2=size=320x180:rate=12:duration=1",
    "-c:v",
    "mjpeg",
    source,
  ]);

  const transformed = await transformVisual(
    {
      ffmpegExecutable: "/opt/homebrew/bin/ffmpeg",
      workRoot: root,
    },
    {
      absolutePath: source,
      kind: "video",
      relativePath: "VIDEO/source.avi",
      sourceKey: "c".repeat(64),
    },
    "paired_rotated",
  );

  assert.equal(transformed.descriptionImagePath, undefined);
  assert.deepEqual(
    transformed.outputs.map((output) => output.fileName),
    [
      "source-symmetric-positive.mp4",
      "source-symmetric-negative.mp4",
    ],
  );
  for (const output of transformed.outputs) {
    const { stdout } = await run("/opt/homebrew/bin/ffprobe", [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=codec_name,width,height",
      "-of",
      "csv=p=0",
      output.absolutePath,
    ]);
    assert.equal(stdout.trim(), "h264,320,320");
  }
});
