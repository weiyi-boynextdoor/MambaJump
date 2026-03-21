# Run MambaJump Server

## What This Server Does

The Go server in [server/main.go](/Users/yiwei/Desktop/work/MambaJump/server/main.go) provides:

- personal jump score tracking
- simple score stats
- local file upload for videos or thumbnails
- static serving for uploaded files

It stores data locally in:

- [server/data/store.json](/Users/yiwei/Desktop/work/MambaJump/server/data/store.json) after first run
- [server/uploads](/Users/yiwei/Desktop/work/MambaJump/server/uploads) after first upload

## Run Locally

From the project root:

```bash
cd server
go run .
```

The server starts on:

```text
http://localhost:8080
```

## Optional Environment Variables

You can override the defaults:

```bash
PORT=9090 go run .
```

```bash
PORT=9090 MAMBAJUMP_DATA_FILE=tmp/store.json MAMBAJUMP_UPLOAD_DIR=tmp/uploads go run .
```

Defaults:

- `PORT=8080`
- `MAMBAJUMP_DATA_FILE=data/store.json`
- `MAMBAJUMP_UPLOAD_DIR=uploads`

## Quick API Checks

Health check:

```bash
curl http://localhost:8080/health
```

Create a score:

```bash
curl -X POST http://localhost:8080/api/scores \
  -H "Content-Type: application/json" \
  -d '{
    "athlete_name": "Yiwei",
    "jump_height_cm": 52.4,
    "airtime_ms": 654,
    "source_type": "imported_video",
    "notes": "Evening session"
  }'
```

List scores:

```bash
curl http://localhost:8080/api/scores
```

Get stats:

```bash
curl http://localhost:8080/api/stats
```

Upload a file:

```bash
curl -X POST http://localhost:8080/api/uploads \
  -F "file=@/absolute/path/to/jump.mov"
```

List uploads:

```bash
curl http://localhost:8080/api/uploads
```

Create a score linked to an uploaded file:

1. Upload a file and copy the returned `id`.
2. Create the score:

```bash
curl -X POST http://localhost:8080/api/scores \
  -H "Content-Type: application/json" \
  -d '{
    "athlete_name": "Yiwei",
    "jump_height_cm": 55.1,
    "media_asset_id": "asset_replace_me"
  }'
```

## Endpoints

- `GET /health`
- `GET /api/scores`
- `POST /api/scores`
- `GET /api/scores/{id}`
- `DELETE /api/scores/{id}`
- `GET /api/stats`
- `GET /api/uploads`
- `POST /api/uploads`
- `GET /uploads/{filename}`
