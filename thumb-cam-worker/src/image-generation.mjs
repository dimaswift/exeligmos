import { randomInt } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";

import { createAgent } from "../../agent-module/src/index.mjs";

export async function generateMirroredImage(config, prompt, options = {}) {
  const axis = "vertical";
  const agent = createAgent({
    provider: config.imageProvider,
    baseUrl: config.imageBaseUrl,
    apiKey: config.imageApiKey,
    timeoutMs: config.imageTimeoutMs,
  });
  const response = await agent.generateImage({
    model: config.imageModel,
    prompt,
    size: config.imageSize,
    steps: config.imageSteps,
    guidance: config.imageGuidance,
  });
  const image = response.images[0];
  if (image === undefined) throw new Error("The image agent returned no image.");

  const directory = path.join(config.workRoot, "generated");
  await mkdir(directory, { recursive: true });
  const stem = `generated-${Date.now()}-${randomInt(1_000_000)}`;
  const extension = image.mediaType === "image/jpeg" ? "jpg" : "png";
  const originalPath = path.join(directory, `${stem}-original.${extension}`);
  const outputPath = path.join(directory, `${stem}-${axis}.${extension}`);
  await writeFile(originalPath, Buffer.from(image.data, "base64"));
  try {
    await run(
      config.ffmpegExecutable,
      [
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        originalPath,
        "-filter_complex",
        verticalSymmetryFilter(),
        "-map",
        "[symmetry]",
        "-frames:v",
        "1",
        outputPath,
      ],
      options.spawn ?? spawn,
    );
    return {
      absolutePath: outputPath,
      contentType: image.mediaType,
      fileName: `generated-${axis}.${extension}`,
      axis,
      model: response.model,
      cleanup: async () => {
        await Promise.allSettled([
          rm(originalPath, { force: true }),
          rm(outputPath, { force: true }),
        ]);
      },
    };
  } catch (error) {
    await Promise.allSettled([
      rm(originalPath, { force: true }),
      rm(outputPath, { force: true }),
    ]);
    throw error;
  }
}

export function verticalSymmetryFilter() {
  return [
    "[0:v]crop=iw/2:ih:0:0,split=2[original][reflection]",
    "[reflection]hflip[mirrored]",
    "[original][mirrored]hstack=inputs=2[symmetry]",
  ].join(";");
}

function run(executable, arguments_, spawnProcess) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(executable, arguments_, {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve();
      else {
        reject(
          new Error(
            `${executable} image flip failed (${signal ?? `exit ${code}`}): ${stderr.trim()}`,
          ),
        );
      }
    });
  });
}
