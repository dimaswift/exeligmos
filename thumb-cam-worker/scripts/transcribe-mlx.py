#!/usr/bin/env python3

import json
import pathlib
import sys

import mlx_whisper


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: transcribe-mlx.py INPUT_AUDIO MODEL_REPOSITORY OUTPUT_JSON"
        )

    input_path, model_repository, output_path = sys.argv[1:]
    result = mlx_whisper.transcribe(
        input_path,
        path_or_hf_repo=model_repository,
    )
    text = result.get("text") if isinstance(result, dict) else None
    pathlib.Path(output_path).write_text(
        json.dumps({"text": text}, ensure_ascii=False),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
