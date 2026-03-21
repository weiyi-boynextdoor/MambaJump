# Backend Server Survey for MambaJump

## What The App Needs

Today `MambaJump` is a local-first iOS app:

- jump detection and height estimation happen fully on-device
- users can analyze live camera input or imported video
- the app currently stores almost nothing besides a small settings value

Because of that, the backend should start as a **results-tracking and sync system**, not as a video-processing or ML-inference system.

The first backend version should support:

- user accounts or anonymous device-based profiles
- saving jump results over time
- storing metadata about sessions and clips
- optional upload of source videos or thumbnails
- cross-device sync later
- simple progress/history views and personal best tracking

It should probably **not** do these things in v1:

- run body-pose inference on the server
- process every uploaded video in the cloud
- build a complicated event-driven microservice system

## Recommended Direction

If you want the best default choice for this app, use:

- `Go`
- `PostgreSQL`
- a small modular monolith API
- `REST` for the first version
- `Redis` only when caching or async jobs become useful
- object storage only if you decide to keep uploaded videos

Short version:

- `Go` is a strong fit if you prefer the China backend ecosystem and want good long-term operational characteristics.
- `PostgreSQL` is the safest long-term database choice for user data, results, and analytics.
- A `modular monolith` is much simpler than microservices and is exactly right for an app at this stage.
- `REST` is enough for result tracking and mobile sync. You do not need GraphQL yet.

If you want the fastest solo-builder path with less backend code, the main alternative is still:

- `Supabase`
- `Postgres`
- storage + auth + row-level security
- a very thin custom API only where needed

## Architecture Choices

### Option 1: Go + Postgres + Modular Monolith

Best for: the strongest recommendation if you want a real backend that can grow large.

Suggested stack:

- backend language: `Go`
- framework/router: `Gin`, `Echo`, `Fiber`, or `chi`
- database: `PostgreSQL`
- query layer: `sqlc`, `GORM`, `Ent`, or `pgx`
- auth: JWT-based auth or hosted auth provider
- storage: `S3`/`Cloudflare R2`/`MinIO` for videos and thumbnails
- cache/queue later: `Redis`

Why it fits MambaJump:

- mobile apps usually need straightforward CRUD plus auth plus uploads before anything fancy
- Go is excellent for stable APIs, concurrency, low memory usage, and operational simplicity
- Go is widely used in China for backend services, which helps if you want to hire or align with common production practices later
- the backend can stay focused on results, users, history, and progress summaries

Pros:

- strong performance and simple deployment
- good fit for high-concurrency APIs and background jobs
- easy to containerize and scale
- popular backend choice in China
- clearer path from small app backend to larger service platform

Cons:

- less ergonomic than TypeScript for very rapid product prototyping
- fewer batteries-included app-level abstractions than some higher-level frameworks
- if you add AI-heavy features later, you will probably still want a separate Python service

Verdict:

- this is the best default if you want MambaJump to start simple but still have room to grow into a larger platform

### Option 2: Go + Postgres + Event-Ready Monolith

Best for: planning ahead for larger scale without prematurely splitting into microservices.

Suggested stack:

- core API: `Go`
- database: `PostgreSQL`
- cache: `Redis`
- async queue: `Redis`, `Kafka`, or `RabbitMQ` later
- storage: `S3`-compatible object storage

What this means:

- still ship one main backend service first
- design modules cleanly so they can later be extracted if needed
- introduce background jobs and event streams only when real product features require them

Why it fits:

- if you later add coach messaging, training plans, notifications, wearables, or media processing, this structure evolves cleanly
- it avoids the cost of an early microservice architecture

Pros:

- future-friendly without overengineering day 1
- lets you add jobs, recommendation pipelines, and analytics incrementally

Cons:

- requires some architectural discipline early on
- slightly more upfront design work than a very casual CRUD server

Verdict:

- this is often the best practical interpretation of "build for future scale" for a startup-style app

### Option 3: Python + FastAPI + Postgres

Best for: if you expect server-side analytics or ML to become important soon.

Suggested stack:

- backend language: `Python`
- framework: `FastAPI`
- database: `PostgreSQL`
- ORM: `SQLAlchemy` or `SQLModel`

Why it fits:

- there are already Python scripts in this repo
- if you later move some analysis, batch scoring, or experimentation server-side, Python is convenient

Pros:

- very fast to build APIs
- excellent for data science and ML workflows
- strong ecosystem for recommendation systems and model pipelines

Cons:

- not as strong as Go for a long-lived high-throughput core API
- easier to accumulate loose schemas and uneven service boundaries

Verdict:

- use Python later for AI and data services, but I would not make it the main transactional backend if your instinct is Go

### Option 4: Supabase First

Best for: fastest path to shipped syncing and history.

Suggested stack:

- platform: `Supabase`
- database: `PostgreSQL`
- auth: `Supabase Auth`
- storage: `Supabase Storage`
- server logic: SQL policies, edge functions, or a very small custom API

Why it fits:

- MambaJump mainly needs auth, result storage, history queries, and maybe video uploads
- Supabase gives those pieces quickly without making you build every backend primitive yourself

Pros:

- fastest time to first sync feature
- Postgres underneath, so the data model still scales reasonably
- good fit for solo development

Cons:

- some platform coupling
- less aligned with your preference for a Go-owned backend
- complex business logic can get awkward if pushed too deeply into edge functions or SQL

Verdict:

- this is the best shortcut if your main goal is shipping result tracking quickly rather than building a Go backend

## Database Choice

### PostgreSQL

Recommended database: `PostgreSQL`

Why:

- excellent for relational app data
- works well for users, workouts, attempts, leaderboards, and history queries
- supports JSON when you need flexible measurement payloads
- easy to host almost anywhere

This app naturally maps to relational tables such as:

- `users`
- `devices`
- `jump_sessions`
- `jump_attempts`
- `media_assets`
- `personal_bests`

### Redis

Recommended later, not required on day 1.

Use it for:

- caching hot stats
- rate limiting
- session storage if needed
- background job queues
- temporary AI coach conversation state

Do not add it until you actually need it.

### SQLite

Good for:

- local app storage on device
- prototypes

Not ideal as the main backend database because:

- weaker concurrency and operational story for a networked API

### MongoDB

Not recommended for v1.

Reason:

- MambaJump data is naturally relational and queryable over time
- Postgres is a better fit for progress charts, best-result summaries, and user/session joins

## Recommended App/Server Boundary

Keep these on the iPhone:

- Vision pose detection
- frame-by-frame video analysis
- jump detection heuristics
- raw camera access

Send these to the backend:

- final jump result
- airtime
- estimated jump height
- timestamps
- session metadata
- source type such as `live_camera` or `imported_video`
- optional notes, tags, and clip references

This boundary is important because it keeps:

- latency low
- battery/network costs manageable
- backend complexity much lower
- privacy better if users do not need to upload raw videos

## Recommended API Shape

Use `REST` first.

Suggested endpoints:

- `POST /auth/signup`
- `POST /auth/login`
- `GET /me`
- `POST /jump-sessions`
- `POST /jump-attempts`
- `GET /jump-attempts`
- `GET /stats/personal-best`
- `GET /stats/history`
- `POST /media/upload-url`

Why REST first:

- simple for Swift networking
- easy to debug
- enough for CRUD plus summary stats
- lower complexity than GraphQL

Use GraphQL only if you later build:

- a richer web dashboard
- highly nested data views
- many frontend clients with different data-shape needs

## Suggested Data Model

### Core entities

`users`

- id
- email or auth provider id
- created_at

`devices`

- id
- user_id
- platform
- app_version
- created_at

`jump_sessions`

- id
- user_id
- device_id
- source_type
- started_at
- ended_at
- notes

`jump_attempts`

- id
- session_id
- measured_at
- airtime_ms
- jump_height_cm
- confidence
- algorithm_version
- max_airtime_setting
- video_start_seconds
- video_end_seconds

`media_assets`

- id
- user_id
- attempt_id
- storage_path
- kind
- duration_seconds
- created_at

You may also want a denormalized stats table or materialized view later for:

- personal best
- weekly average
- attempt counts
- last-30-day trend

## Deployment Shape

Start with a single deployable backend service:

- Go API server
- Postgres
- optional object storage
- optional worker
- optional Redis later

This is a `modular monolith`, not a microservice setup.

Recommended internal modules:

- `auth`
- `users`
- `jump_sessions`
- `jump_attempts`
- `stats`
- `media`

Why this is enough:

- the app is still early-stage
- there is no traffic pattern here that justifies microservices
- operational simplicity matters more than theoretical scale

Only add a worker when you need asynchronous jobs such as:

- thumbnail generation
- video cleanup
- delayed stats recomputation
- exports
- coach notifications

## If MambaJump Grows Large

If this app grows into a larger sports platform, the likely path is:

1. keep one Go service for the main product API
2. add Redis for caching and job queues
3. add background workers
4. add event streaming only when features truly need it
5. split services only after module boundaries and traffic patterns become obvious

Possible future service split:

- `user-service`
- `training-service`
- `results-service`
- `media-service`
- `coach-service`
- `notification-service`

Do not start there now.

The right way to "prepare for scale" is:

- clean module boundaries
- explicit API contracts
- good observability
- idempotent jobs
- careful schema design

not early microservices.

## If You Add An AI Coach

An AI coach should usually be a separate capability, not baked into the main app API from day 1.

Recommended future shape:

- core product backend: `Go`
- transactional database: `PostgreSQL`
- cache and queue: `Redis`
- AI/recommendation service: `Python`
- model provider or self-hosted inference: separate from the core API

Why:

- your main backend handles users, plans, results, billing, and sync
- the AI layer handles plan generation, recommendation, summarization, and coaching logic
- Python is still the easiest place to build model pipelines, evaluation, and experimentation

Data the AI coach will eventually need:

- jump history
- training adherence
- recovery timing
- user goals
- body metrics
- wearable integrations
- feedback on whether a plan helped

The biggest long-term advantage will come from your data model and product feedback loops, not from putting AI into the first backend version.

## Authentication Recommendation

For v1, pick one of these:

1. `Sign in with Apple` + backend-issued user record
2. phone/email login
3. anonymous device-backed accounts first, then upgrade later

For an iOS-first app, `Sign in with Apple` is a very strong choice if you want proper accounts early.

If you mainly want personal syncing and are not launching publicly yet, anonymous accounts plus a device token can be enough for a first pass, but it is weaker long term.

## Video Upload Recommendation

Do not require raw video uploads in v1 unless you truly need them.

Prefer this order:

1. store only the final measurement result and metadata
2. optionally store a thumbnail or short preview frame
3. only later store full videos for premium coaching or remote review features

Reason:

- raw video storage increases cost, privacy burden, and product complexity

## What I Would Choose

### If you want the best balanced long-term stack

- backend: `Go`
- router/framework: `Gin` or `Echo`
- database: `PostgreSQL`
- query layer: `sqlc` + `pgx`, or `GORM` if you want faster iteration
- architecture: `modular monolith`
- API: `REST`
- storage: `S3`-compatible object storage only if you keep media
- cache later: `Redis`

### If you want the most future-friendly Go approach

- start with one Go service
- keep modules clean enough to split later
- introduce Redis and workers before introducing microservices
- add a separate Python AI service only when coach features become real

### If you want the fastest path to ship

- backend: `Supabase`
- database: `PostgreSQL`
- architecture: managed backend + thin custom logic
- API: Supabase client APIs plus a small custom service only where needed

## Final Recommendation For MambaJump

For this app specifically, I would choose:

- `Go`
- `PostgreSQL`
- `REST`
- `modular monolith`
- keep jump analysis on-device
- store only results and metadata first
- add `Redis` only when caching or jobs become necessary
- add a separate `Python` AI service later if you build coaching features

Why:

- the current app is already doing the expensive computer-vision work locally
- your first backend problem is product data, not ML infrastructure
- Go gives you a strong production backend foundation that aligns with your preference and scales well if the app becomes much larger
- this path leaves room for an AI coach later without forcing the main backend to absorb ML complexity too early

## Sensible Build Order

1. add local on-device persistence in the iOS app for jump history
2. define the backend schema around `users`, `sessions`, and `attempts`
3. build a Go API for auth and result sync
4. sync results only
5. add stats endpoints
6. add Redis only if you need caching or async jobs
7. add optional media upload later
8. add a separate AI coach service later

That order keeps the product simple and prevents you from overbuilding infrastructure before the tracking feature is useful.
