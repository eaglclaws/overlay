"""FastAPI service: build a transparent PNG overlay from uploaded logos at given coordinates."""

from __future__ import annotations

import io
import json
import os
import asyncio
import tempfile
import urllib.error
import urllib.request
from typing import Annotated, Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from PIL import Image

app = FastAPI(title="overlay-api", version="1.0.0")

OVERLAY_PNG_PATH = "/data/overlay-root/overlay.png"
FILTER_API_URL = "http://127.0.0.1:8081/api/streams/live.stream/send-to-filter"
FILTER_PAYLOAD = {
    "arg": f"file://{OVERLAY_PNG_PATH}",
    "command": "url",
    "target": "1.stream_overlay_top_left",
}


def _parse_assignments(raw: str) -> list[tuple[str, int, int]]:
    """Parse coordinates JSON into paint order: list of (basename, x, y). Same file may repeat."""
    try:
        data: Any = json.loads(raw)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON for coordinates: {e}") from e

    if not isinstance(data, list):
        raise HTTPException(status_code=400, detail="coordinates must be a JSON array")

    out: list[tuple[str, int, int]] = []
    for i, item in enumerate(data):
        if not isinstance(item, dict):
            raise HTTPException(
                status_code=400,
                detail=f"coordinates[{i}] must be an object with \"file\", \"x\", and \"y\"",
            )
        file_key = item.get("file") if item.get("file") is not None else item.get("name")
        if not isinstance(file_key, str) or not file_key.strip():
            raise HTTPException(
                status_code=400,
                detail=f"coordinates[{i}] must include a non-empty string \"file\" (or \"name\") matching the upload filename",
            )
        basename = os.path.basename(file_key.strip())
        if not basename:
            raise HTTPException(
                status_code=400,
                detail=f"coordinates[{i}].file must resolve to a non-empty basename",
            )
        if "x" not in item or "y" not in item:
            raise HTTPException(
                status_code=400,
                detail=f"coordinates[{i}] must include numeric \"x\" and \"y\"",
            )
        try:
            x, y = int(item["x"]), int(item["y"])
        except (TypeError, ValueError) as e:
            raise HTTPException(
                status_code=400,
                detail=f"coordinates[{i}].x and .y must be integers",
            ) from e
        out.append((basename, x, y))
    return out


def _index_uploads_by_basename(logos: list[UploadFile]) -> dict[str, UploadFile]:
    by_name: dict[str, UploadFile] = {}
    for u in logos:
        b = os.path.basename(u.filename or "")
        if not b:
            raise HTTPException(
                status_code=400,
                detail="Each logo upload must have a filename that matches coordinates[].file",
            )
        if b in by_name:
            raise HTTPException(
                status_code=400,
                detail=f"Duplicate upload filename {b!r}; each file must have a unique name",
            )
        by_name[b] = u
    return by_name


@app.get("/")
async def root() -> dict[str, str]:
    return {"service": "overlay-api", "docs": "/docs"}


@app.post("/create-overlay")
async def create_overlay(
    coordinates: Annotated[
        str,
        Form(
            description=(
                'JSON array of { "file": "<filename>", "x": int, "y": int } — '
                '"file" is the upload basename (must match a part\'s filename). '
                "Order is paint order (first = bottom)."
            ),
        ),
    ],
    logos: Annotated[list[UploadFile], File()],
) -> Response:
    """
    Build a transparent RGBA PNG sized to the tight bounding box of all logos at their
    coordinates (top-left of each image). Placements are keyed by filename, not multipart order.
    """
    assignments = _parse_assignments(coordinates)
    if not assignments:
        raise HTTPException(status_code=400, detail="coordinates must list at least one placement")
    if not logos:
        raise HTTPException(status_code=400, detail="At least one logo file is required")

    uploads_by_name = _index_uploads_by_basename(logos)

    referenced = {name for name, _, _ in assignments}
    missing = sorted(referenced - uploads_by_name.keys())
    if missing:
        raise HTTPException(
            status_code=400,
            detail=f"No upload for file(s): {', '.join(repr(m) for m in missing)}",
        )
    extra = sorted(uploads_by_name.keys() - referenced)
    if extra:
        raise HTTPException(
            status_code=400,
            detail=f"Upload(s) not referenced in coordinates: {', '.join(repr(e) for e in extra)}",
        )

    raw_by_name: dict[str, bytes] = {}
    for name in uploads_by_name:
        body = await uploads_by_name[name].read()
        if not body:
            raise HTTPException(status_code=400, detail=f"Upload {name!r} is empty")
        raw_by_name[name] = body

    image_cache: dict[str, Image.Image] = {}

    def get_logo_rgba(basename: str) -> Image.Image:
        if basename not in image_cache:
            try:
                im = Image.open(io.BytesIO(raw_by_name[basename])).convert("RGBA")
            except Exception as e:
                raise HTTPException(
                    status_code=400,
                    detail=f"File {basename!r} is not a valid image: {e}",
                ) from e
            image_cache[basename] = im
        return image_cache[basename]

    loaded: list[tuple[Image.Image, tuple[int, int]]] = []
    for basename, x, y in assignments:
        logo = get_logo_rgba(basename)
        loaded.append((logo, (x, y)))

    min_x = min(x for _, (x, _) in loaded)
    min_y = min(y for _, (_, y) in loaded)
    max_x = max(x + im.width for im, (x, _) in loaded)
    max_y = max(y + im.height for im, (_, y) in loaded)

    canvas_w = max_x - min_x
    canvas_h = max_y - min_y
    if canvas_w < 1 or canvas_h < 1:
        raise HTTPException(status_code=400, detail="Computed canvas has invalid dimensions")
    if canvas_w > 16384 or canvas_h > 16384:
        raise HTTPException(status_code=400, detail="Resulting image exceeds maximum size (16384 px)")

    base = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    for logo, (x, y) in loaded:
        px = x - min_x
        py = y - min_y
        layer = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
        layer.paste(logo, (px, py), logo)
        base = Image.alpha_composite(base, layer)

    buf = io.BytesIO()
    base.save(buf, format="PNG")
    png_bytes = buf.getvalue()

    async def write_overlay_file() -> None:
        os.makedirs(os.path.dirname(OVERLAY_PNG_PATH), exist_ok=True)
        directory = os.path.dirname(OVERLAY_PNG_PATH) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".overlay-", suffix=".png", dir=directory)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(png_bytes)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, OVERLAY_PNG_PATH)
        finally:
            try:
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)
            except OSError:
                pass

    def notify_filter_api() -> None:
        data = json.dumps(FILTER_PAYLOAD).encode("utf-8")
        req = urllib.request.Request(
            FILTER_API_URL,
            method="PUT",
            data=data,
            headers={
                "Accept": "application/json, */*;q=0.5",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status < 200 or resp.status >= 300:
                raise RuntimeError(f"filter API returned HTTP {resp.status}")

    try:
        await write_overlay_file()
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"Failed to write overlay PNG: {e}") from e

    try:
        await asyncio.to_thread(notify_filter_api)
    except urllib.error.URLError as e:
        raise HTTPException(status_code=502, detail=f"Failed to call filter API: {e}") from e
    except RuntimeError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e

    return Response(content=png_bytes, media_type="image/png")
