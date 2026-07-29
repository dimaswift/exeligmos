import { mkdir, readFile, readdir, rm } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const runFile = promisify(execFile);

export function symmetryOutputMode() {
  return "paired_rotated";
}

export function parseSymmetry(value) {
  if (value !== "paired_rotated")
    throw new Error(`Unsupported symmetry selection: ${value}`);
  return { sides: ["positive", "negative"], rotateDegrees: 90 };
}

export async function transformVisual(config, item, symmetry) {
  const selection = parseSymmetry(symmetry);
  const outputExtension = item.kind === "photo" ? ".jpg" : ".mp4";
  const outputs = selection.sides.map((side) => ({
    side,
    absolutePath: path.join(
      config.workRoot,
      "processed",
      `${item.sourceKey}-${side}-rotated${outputExtension}`,
    ),
    contentType: item.kind === "photo" ? "image/jpeg" : "video/mp4",
    fileName: `${path.parse(item.relativePath).name}-symmetric-${side}${outputExtension}`,
  }));
  await mkdir(path.dirname(outputs[0].absolutePath), { recursive: true });
  const temporaryPaths = outputs.map((output) => output.absolutePath);
  const common = [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    item.absolutePath,
  ];
  try {
    for (const output of outputs) {
      const filter = mirrorFilter(output.side);
      if (item.kind === "photo") {
        await runFile(
          config.ffmpegExecutable,
          [
            ...common,
            "-filter_complex",
            filter,
            "-map",
            "[out]",
            "-frames:v",
            "1",
            "-c:v",
            "mjpeg",
            "-q:v",
            "2",
            "-map_metadata",
            "-1",
            output.absolutePath,
          ],
          commandOptions(),
        );
        continue;
      }
      await runFile(
        config.ffmpegExecutable,
        [
          ...common,
          "-filter_complex",
          filter,
          "-map",
          "[out]",
          "-map",
          "0:a?",
          "-c:v",
          "h264_videotoolbox",
          "-b:v",
          "8M",
          "-maxrate",
          "12M",
          "-bufsize",
          "16M",
          "-realtime",
          "true",
          "-allow_sw",
          "1",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-b:a",
          "192k",
          "-movflags",
          "+faststart",
          "-map_metadata",
          "-1",
          output.absolutePath,
        ],
        commandOptions(),
      );
    }
    return {
      outputs,
      descriptionImagePath:
        item.kind === "photo" ? outputs[0].absolutePath : undefined,
      temporaryPaths,
    };
  } catch (error) {
    await removePaths(temporaryPaths);
    throw error;
  }
}

export async function transcribeAudio(config, absolutePath) {
  const outputDirectory = path.join(
    config.workRoot,
    "transcripts",
    `${Date.now()}-${Math.random().toString(16).slice(2)}`,
  );
  await mkdir(outputDirectory, { recursive: true });
  try {
    await runFile(
      config.whisperExecutable,
      [
        absolutePath,
        "--model",
        config.whisperModel,
        "--output_format",
        "json",
        "--output_dir",
        outputDirectory,
        "--fp16",
        "False",
        "--verbose",
        "False",
      ],
      commandOptions(64 * 1024 * 1024),
    );
    const output = (await readdir(outputDirectory)).find((name) =>
      name.endsWith(".json"),
    );
    if (output === undefined)
      throw new Error("Whisper did not create a JSON transcript.");
    const document = JSON.parse(
      await readFile(path.join(outputDirectory, output), "utf8"),
    );
    const text = typeof document.text === "string" ? document.text.trim() : "";
    if (text === "") throw new Error("Whisper returned an empty transcript.");
    return text;
  } catch (cause) {
    const stderr = typeof cause?.stderr === "string" ? cause.stderr : "";
    if (/CERTIFICATE_VERIFY_FAILED/.test(stderr)) {
      throw new Error(
        `Whisper model ${config.whisperModel} is not cached and Python could not verify its download certificate. Run the Python “Install Certificates.command” helper or select an installed model.`,
        { cause },
      );
    }
    if (cause?.code === "ENOENT") {
      throw new Error(
        `Whisper executable ${config.whisperExecutable} was not found.`,
        { cause },
      );
    }
    throw new Error(
      `Whisper failed for ${path.basename(absolutePath)}: ${
        stderr.trim().split("\n").at(-1) ?? cause?.message ?? "unknown error"
      }`,
      { cause },
    );
  } finally {
    await rm(outputDirectory, { force: true, recursive: true });
  }
}

export async function cleanupVisualArtifacts(transformed) {
  if (!Array.isArray(transformed?.temporaryPaths)) return;
  await removePaths(transformed.temporaryPaths);
}

export function mediaTypeForUpload(item, transformed) {
  if (transformed !== undefined) return transformed.contentType;
  const extension = path.extname(item.relativePath).toLowerCase();
  return (
    new Map([
      [".aac", "audio/aac"],
      [".aif", "audio/aiff"],
      [".aiff", "audio/aiff"],
      [".flac", "audio/flac"],
      [".m4a", "audio/mp4"],
      [".mp3", "audio/mpeg"],
      [".ogg", "audio/ogg"],
      [".opus", "audio/opus"],
      [".wav", "audio/wav"],
    ]).get(extension) ?? "application/octet-stream"
  );
}

export function fileNameForUpload(item, transformed) {
  return transformed?.fileName ?? path.basename(item.relativePath);
}

function mirrorFilter(side) {
  const landscapeTwoToOne =
    "crop='min(iw,2*ih)':'min(ih,iw/2)',setsar=1";
  if (side === "positive") {
    return (
      `[0:v]${landscapeTwoToOne},split=2[original][copy];` +
      "[copy]vflip[mirror];" +
      "[original][mirror]vstack,transpose=clock[out]"
    );
  }
  return (
    `[0:v]${landscapeTwoToOne},split=2[copy][original];` +
    "[copy]vflip[mirror];" +
    "[mirror][original]vstack,transpose=clock[out]"
  );
}

function commandOptions(maxBuffer = 16 * 1024 * 1024) {
  return { encoding: "utf8", maxBuffer };
}

async function removePaths(paths) {
  await Promise.all(
    paths.map((entry) => rm(entry, { force: true, recursive: false })),
  );
}
