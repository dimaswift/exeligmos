# THUMB_CAM worker

This macOS worker watches for an exact `THUMB_CAM` volume, scans its `AUDIO`,
`VIDEO`, and `PHOTO` folders, and creates public Fractonica records attributed
to the `THUMB` device. On macOS it verifies the path is a real diskutil mount,
so a stale ordinary `/Volumes/THUMB_CAM` directory is never scanned.

The server job-item table is the durable cache. A source file's identity is its
exact lowercase SHA-256 content digest, so files already accepted by the server
are not queued again even after the worker or Mac restarts. Names and paths are
metadata only: a new file reusing `IMG00001.JPG` is accepted when its bytes are
different, while unchanged bytes are ignored even if renamed or moved.

## Processing behavior

- Files are sorted by capture time and grouped while the whole group remains
  within one catalog-derived Saros: `271.30686904907225` seconds.
- A newly discovered group remains open for one full Saros. If another capture
  joins that window, the close timer restarts for the enlarged group.
- A file must remain unchanged across two scans and be at least 30 seconds old
  by default. The worker also verifies its stat identity before and after
  hashing/probing. Any supported file that is young or still changing keeps the
  current Saros submission window open until a later fully settled poll.
- Hash and ffprobe results are cached in memory while the file's stat identity
  is unchanged. New descriptions are bounded to two concurrent files by
  default. Duplicate hashes within one scan keep only the earliest capture.
- Before a job is submitted, every member of its mature batch is copied into a
  source-keyed worker snapshot. Each copy is atomically published only after its
  byte length and SHA-256 match the scan, with two concurrent copies by default.
- Processing and uploads read only those snapshots. Verified snapshots survive
  camera removal, worker restarts, and failed retries; they are deleted after
  their record group completes.
- Each horizontal 2:1 photo or video is mirrored across its long axis into two
  separate square files: one for each reflection direction. Both squares are
  rotated 90 degrees into the camera's intended vertical orientation and
  attached independently to the record.
- Ollama describes processed photos with `gemma4` by default. Videos are never
  sent to Gemma.
- MLX Whisper transcribes audio locally with
  `mlx-community/whisper-large-v3-mlx` by default; Gemma repairs likely
  recognition errors without inventing content.
- Gemma first describes each photo and normalizes each audio transcript.
  It then combines the photo and audio observations into one short,
  first-person diary entry; video descriptions are excluded from this
  record-wide summary.
- After the summary is complete, Gemma chooses the single emoji that best
  represents the finished record text.
- Gemma also converts the final summary into a visual prompt. MLX Studio
  generates a square image with `schnell`. The worker corrects MLX Studio's
  inverted output orientation, then preserves one half and reflects it across
  the vertical axis. If generation is
  unavailable, the record completes without the generated attachment.
- Processed visual media and original audio are uploaded through Fractonica's
  verified upload-session API. Each audio file also gets a readable
  `<source>.transcript.md` attachment containing the raw MLX Whisper output.
- Temporary generated media and local transcript files are removed from the
  worker directory after each attempt.
- The record's `occurredAt` is the first source-media capture time.
- Every record stores the same depth-eight Saros context as the web/iOS record
  flow, including the closest octal phase and two past/two future spikes. Plain
  archives can therefore search and filter THUMB records by Saros.
- Records carry compact iOS snapshot identity for the `THUMB` camera device
  without duplicating the attachment list inside JSON.
- Ollama generates an `embeddinggemma` vector for the final text and the worker
  stores it through the record embedding API.
- Long ffmpeg, MLX Whisper, upload, and model-agent stages renew the server activity
  lease every 30 seconds. If the worker exits, `/jobs` becomes idle after two
  minutes while the unfinished item remains retryable.
- If another worker advances the same job revision, this worker reloads the
  winning state and yields that job until the next poll instead of competing
  with repeated progress updates.

Source files on the camera are never renamed, changed, or deleted.

## Requirements

- Node.js 24 or newer
- `ffmpeg` and `ffprobe`
- Ollama running locally when using the default local description or embedding
  agents
- Python with the `mlx-whisper` package installed
- MLX Studio on `http://127.0.0.1:8001` for optional generated attachments
- a Fractonica `THUMB` device of kind `agent`
- an API key bound to that device with:
  `jobs:read`, `jobs:write`, `records:read`, `records:write`, `media:read`,
  and `media:write`

## Configure

With the sync server running, provision the `THUMB` agent, issue its scoped API
key, and create the ignored local config files:

```sh
npm run configure
```

The command asks for your Fractonica login and password. It never stores the
password. The generated API key is stored in the ignored `.env` file with mode
`0600`; `thumb-cam.config.json` contains only non-secret settings. Configuration
also installs and starts a per-user macOS LaunchAgent. It stays alive across
camera disconnects and starts again automatically when you log in, so plugging
in the registered volume is enough to begin scanning.

All JSON settings also have environment-variable overrides. The most useful
ones are:

```text
THUMB_CAM_DESCRIPTION_PROVIDER
THUMB_CAM_DESCRIPTION_BASE_URL
THUMB_CAM_DESCRIPTION_API_KEY
THUMB_CAM_DESCRIPTION_MODEL
THUMB_CAM_DESCRIPTION_PROMPT
THUMB_CAM_EMBEDDING_PROVIDER
THUMB_CAM_EMBEDDING_BASE_URL
THUMB_CAM_EMBEDDING_API_KEY
THUMB_CAM_EMBEDDING_MODEL
THUMB_CAM_IMAGE_BASE_URL
THUMB_CAM_IMAGE_API_KEY
THUMB_CAM_IMAGE_MODEL
THUMB_CAM_IMAGE_SIZE
THUMB_CAM_IMAGE_STEPS
THUMB_CAM_IMAGE_GUIDANCE
THUMB_CAM_IMAGE_TIMEOUT_MS
THUMB_CAM_PYTHON_EXECUTABLE
THUMB_CAM_WHISPER_MODEL
THUMB_CAM_SERVER_URL
THUMB_CAM_DEVICE_ID
THUMB_CAM_MOUNT_NAME
THUMB_CAM_WORK_ROOT
THUMB_CAM_MINIMUM_FILE_AGE_MS
THUMB_CAM_SCAN_CONCURRENCY
THUMB_CAM_SNAPSHOT_CONCURRENCY
```

The default description prompt is:

```text
describe the image from 1st person perspective as if you have captured it yourself in present tense, like an entry in the diary. Keep it short and informative
```

## Run

Monitor `/Volumes` continuously:

```sh
npm start -- --config thumb-cam.config.json
```

Scan one currently mounted volume and exit:

```sh
npm run once -- --config thumb-cam.config.json
```

One-shot mode also keeps the Saros grouping window open before it exits, so it
can wait a little over four and a half minutes before starting a new group.

Command-line overrides are available for the common settings:

```sh
npm start -- \
  --config thumb-cam.config.json \
  --description-provider ollama \
  --model gemma4 \
  --embedding-provider ollama \
  --embedding-model embeddinggemma \
  --whisper-model mlx-community/whisper-large-v3-mlx \
  --prompt 'your prompt'
```

The worker uses the shared [`@exeligmos/agent`](../agent-module/README.md)
interface. `ollama` supports text, images, and embeddings. `speshu` uses
`https://speshu.ai/api/v1/chat/completions` for text and image requests:

```sh
export SPESHU_API_KEY='...'
npm start -- \
  --config thumb-cam.config.json \
  --description-provider speshu \
  --description-base-url https://speshu.ai/api/v1 \
  --model google/gemini-2.5-flash
```

SpeShu's documented chat API has no embeddings operation, so the default
embedding agent remains Ollama. Agent keys belong in environment variables,
never in `thumb-cam.config.json` or server-managed worker settings. For the
background LaunchAgent, add `SPESHU_API_KEY=...` to the worker's ignored
`.env` file; exported interactive-shell variables are not inherited by
LaunchAgent processes.

The worker first resumes unfinished jobs from verified local snapshots, even
while the camera is absent, then submits a current mounted scan. Completed
media fingerprints remain in the server cache; failed groups can resume with
their saved symmetry and upload state.

Use **Reset cache and counters** on the server's `/workers` page when the
camera should be treated as fresh. The reset deletes this worker's ingestion
jobs and processed-source fingerprints, restarts its displayed statistics at
zero, and advances a cache generation that makes the running worker clear its
in-memory scan state and verified local snapshots on the next poll. Existing
records, uploaded media, and worker logs are preserved.

## Canonical temporal runtime

The worker ships a small dependency-free bundle of the repository's canonical
temporal calculation and reads the canonical generated solar eclipse dataset
directly. It does not start or contact the web application. After changing the
canonical temporal core, regenerate the committed worker bundle:

```sh
npm run temporal:generate
```
