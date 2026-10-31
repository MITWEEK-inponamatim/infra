# ThreatLens

## Struktur workspace empat repo

Empat repo di-checkout sebagai folder **sejajar**, bukan saling bersarang dan bukan submodule:

```text
D:\mitweek\
├── infra\                 # repo ini: Compose, Supabase, dokumentasi
├── frontend\              # repo threatlens-frontend
├── backend\                # repo threatlens-backend
└── analysis-service\       # repo threatlens-analysis-service
```

Clone masing-masing repo ke nama folder tersebut. `docker-compose.yml` di `infra` memakai build context `../frontend`, `../backend`, dan `../analysis-service`; jalankan perintah Compose dari workspace root dengan `-f infra/docker-compose.yml`. Tidak perlu mengubah atau memindahkan kode service ke repo infra.

## Setup

1. Dari workspace root, salin `frontend/.env.example` → `frontend/.env`, `backend/.env.example` → `backend/.env`, `analysis-service/.env.example` → `analysis-service/.env`, dan `infra/supabase/.env.example` → `infra/supabase/.env`.
2. Add Supabase URL + publishable key to frontend; add Supabase URL + secret key to both backends; add `OPENAI_API_KEY` to analysis-service.
3. Add Cloudflare Turnstile keys to frontend/backend env files. Add Google OAuth client ID/secret to `infra/supabase/.env`.
4. Use `http://localhost:3000` as the Supabase Auth site URL and `http://localhost:3000/auth/callback` as callback URL.
5. Run this step from `infra/`. Keep `SERVICE_API_KEY` identical in `backend/.env` and `analysis-service/.env`.
   Browser and file-analysis containers receive derived, scoped keys and never see `SERVICE_API_KEY`. Create their filtered env files without printing either key:

   ```powershell
    $workspace = (Resolve-Path "..").Path
    $lines = [System.IO.File]::ReadAllLines((Join-Path $workspace "analysis-service/.env"))
   $key = $lines | Where-Object { $_ -match '^SERVICE_API_KEY=' }
   if (@($key).Count -ne 1) { throw "Expected one SERVICE_API_KEY in analysis-service/.env" }
   $raw = $key[0].Substring('SERVICE_API_KEY='.Length)
   function New-DerivedKey([string]$domain) {
     $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($raw))
     try { return -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($domain)) | ForEach-Object { $_.ToString('x2') }) } finally { $hmac.Dispose() }
   }
   $browser = @("BROWSER_SERVICE_KEY=$(New-DerivedKey 'threatlens-browser-service')", 'BROWSER_MAX_RESPONSE_MB=20')
   $worker = @("FILE_WORKER_SERVICE_KEY=$(New-DerivedKey 'threatlens-file-service')", 'WORKER_MAX_CONCURRENCY=2', 'WORKER_MAX_BODY_MB=52', 'WORKER_IMAGE_TIMEOUT_SECONDS=45', 'WORKER_APK_TIMEOUT_SECONDS=150')
    [System.IO.File]::WriteAllText((Join-Path $workspace "analysis-service/.env.browser"), ($browser -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $workspace "analysis-service/.env.worker"), ($worker -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
   Remove-Variable raw
   ```

   Rerun this whenever `SERVICE_API_KEY` changes; `docker compose` needs both files to exist. `.env.browser.example` and `.env.worker.example` document the fields.
6. For a fresh database, install Supabase CLI, authenticate, and apply migrations. Run the commands from the workspace root; the snippet enters `infra/`:

   ```sh
    cd infra
    supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   ```

7. Start services:

   ```sh
    docker compose -f infra/docker-compose.yml up --build -d
    ```

    The URL scanner runs Chromium in an isolated, non-root worker with CPU, memory, and process limits. Container Chromium sandbox is disabled because Docker Desktop lacks unprivileged user namespaces; the worker has no direct internet or backend network access, and all browser egress goes through a DNS-pinning proxy that allows only public HTTP/HTTPS on ports 80/443. The file scanner (`analysis-worker`) handles OCR and APK static analysis in a non-root container with a read-only root filesystem, CPU/memory/pid limits, and no internet route at all. Both read derived keys from `analysis-service/.env.browser` and `analysis-service/.env.worker`, which step 5 writes; **`analysis-worker` refuses to start while `FILE_WORKER_SERVICE_KEY` is empty** and prints the fix in its logs. Apply `infra/supabase/migrations/202610300002_langgraph_schema.sql` in the hosted SQL Editor, then set `DATABASE_URL_SESSION` in `analysis-service/.env` to enable LangGraph checkpoints. Without it, URL analysis still runs but reports checkpointing as unavailable.

    Compose serves frontend at `http://localhost:3000`. Update `frontend/.env` `NEXT_PUBLIC_API_BASE_URL` to `http://localhost:8080`.

   Frontend local dev reads `frontend/.env`; Analysis Service reads `analysis-service/.env`; `go run .` from `backend/` reads `backend/.env`. These service folders are siblings of `infra/` in the workspace.

All `.env` files are ignored by Git. Commit only `.env.example` files. Google OAuth and Turnstile setup is required for login.

## Halaman & UI

| Rute | Isi |
|---|---|
| `/` | Landing page publik: hero + `RecognizeCard`, "Modus Penipuan", dan bagian peringatan |
| `/recognize` | Halaman setelah login. Dirender oleh `components/layout/SiteShell.tsx` yang sama dengan landing page; satu-satunya perbedaan ada di navbar: foto profil Google + tombol keluar |
| `/history` | Riwayat scan |
| `/login` | Turnstile + Google OAuth |

Rute `/scan` tidak ada lagi; semua alur login memakai `next=/recognize` (`proxy.ts`, `app/auth/callback/route.ts`, `app/login/page.tsx`, `LandingInteractionGuard`), dan allowlist `safeNext` hanya menerima `/`, `/recognize`, dan `/history`.

**Ikon dibundel, bukan diambil dari Iconify API.** CSP tidak mengizinkan `api.iconify.design`, sehingga `@iconify/react` sempat gagal memuat data dan semua ikon tampil kosong. Sekarang `scripts/build-solar-icons.mjs` memindai `src/` untuk setiap referensi `solar:*`, memotong subset dari `@iconify-json/solar`, lalu menulis `src/components/ui/solar-icons.ts`; `src/components/ui/Icon.tsx` mendaftarkannya sekali lewat `addCollection` dari `@iconify/react/offline`. Setelah menambahkan ikon baru, jalankan `npm run icons` — tanpa itu ikon baru akan tampil kosong. Foto profil Google diizinkan lewat `img-src https://*.googleusercontent.com` di `next.config.ts`.

## Scan service topology

| Service | Role |
|---|---|
| `go-api` | Public API: JWT/session, validation, Storage upload, scan rows, job polling |
| `analysis-service` | Orchestration, LangGraph, risk engine, LLM, Storage reads |
| `browser-gateway` / `browser-worker` / `browser-egress` | Isolated Chromium with a DNS-pinning egress proxy |
| `analysis-worker` | Isolated OCR + APK static analysis (no internet network, non-root, read-only rootfs, CPU/mem/pid limits) |

`analysis-worker` exposes `POST /internal/v1/analyze/image` and `POST /internal/v1/analyze/application`, guarded by the derived `FILE_WORKER_SERVICE_KEY`. It only extracts evidence; every risk decision stays in `analysis-service/app/apk_rules.py` and `app/risk.py`.

Phase 3 scanners:

- **Phone** — `phonenumbers` normalisation to E.164, premium-rate detection, community lookups in `phone_reports`, plus explicit limitations (spoofing, number reuse, unreliable reports). A valid number is never reported as "safe".
- **Image** — bounded PIL decode (format allowlist, pixel budget), Tesseract OCR (`ind+eng`), then the message pipeline and up to two extracted links through the URL scanner.
- **Application** — SHA-256 hash reputation (VirusTotal when configured), zip-bomb pre-check (entry count, per-entry size, total uncompressed size, compression ratio), Androguard static extraction, and deterministic combination rules (SMS + accessibility/overlay/install capability, embedded Telegram bot token, hidden launcher icon, packer hints). The APK is never executed and is only uploaded to VirusTotal when the user ticks `consent_external_upload`.

Unavailable checks are reported per scan in `risk.coverage.checks_unavailable` instead of failing the scan.

## Laporan komunitas nomor telepon

`POST /api/v1/phone-reports` (authenticated) stores user reports, and `POST /internal/v1/phone/normalize` (service key) is the single normalisation implementation: the Go API stores the E.164 value Python computed instead of keeping a second copy of the rules. The write path lives in Go because the user identity lives there.

| Bagian | Detail |
|---|---|
| Body laporan | `{number, default_region, category, note?}` |
| Kategori | closed vocabulary: `penipuan`, `spam`, `telemarketing`, `penagih_utang`, `peniruan_identitas`, `lainnya` |
| Status awal | `pending` — a report never raises risk by itself |
| Dedup | one report per account per number (unique index `phone_reports_reporter_number_key`) → `409 duplicate_report` |
| Rate limit | `PHONE_REPORT_HOURLY_LIMIT` (default 10/hour per account, in-process) |
| Catatan | `note` is capped at 280 characters, moderation-only, never sent to an LLM and never shown to other users |
| Moderasi | `PATCH /internal/v1/phone-reports/{id}` (service key) → `verified`, `rejected`, `rejected_spam`, `pending` |

The trust summary in `analysis-service/app/phone_scanner.py::summarize_reports` is explainable: number of reports, verified reports, distinct reporters, categories, and recency. `high` requires at least two verified reports from two different reporters, so one account repeating itself never reaches `high`. The scan report always keeps the spoofing/number-reuse/report-error limitations, and the UI shows a "Laporkan nomor ini" panel under the phone result.

Apply `infra/supabase/migrations/202610300004_phone_reports_trust.sql` and `infra/supabase/migrations/202610300005_phone_reports_note.sql` in the hosted SQL Editor. Without `0004` duplicates are only caught by the application check; without `0005` the report is still stored and returns `note_saved: false`.

Deliberately **not** implemented: owner-name lookup (Truecaller-style) and any GetContact integration. Both require an account or credentials for a third-party service whose terms forbid it, and they would store other people's personal data without a lawful basis. The product reports "other people flagged this number", never "this number belongs to X".

## Analysis pipeline (graphs, tools, retention)

Every scanner now runs through its own LangGraph state graph in `analysis-service/app/graph/` (`url`, `message`, `phone`, `image`, `application`) with explicit nodes, conditional edges, and a bounded follow-up (URL redirect host change, extracted links from messages/screenshots). `DATABASE_URL_SESSION` enables the `PostgresSaver`; when it is empty the graphs still run and report `langgraph_checkpointer` as unavailable.

The LLM can only call the nine whitelisted tools in `analysis-service/app/tools.py` (`check_url_reputation`, `inspect_website`, `get_page_metadata`, `inspect_forms`, `analyze_application`, `lookup_phone`, `analyze_message`, `extract_image_text`, `search_verification_evidence`). Tools take a `scan_id`/`file_id`, never a path or arbitrary URL, every argument is validated in code, and evidence always comes from what the deterministic pipeline already collected.

Bounded by design:

```sh
AGENT_TOOL_ROUNDS=2        # max tool-calling rounds per LLM pass
AGENT_MAX_TOOL_CALLS=6     # max executed tool calls per scan
EXTERNAL_RETRY_ATTEMPTS=3  # retry/backoff for transient external failures (timeouts, 429, 5xx)
```

Optional integrations stay inert until configured; each one is reported in `checks_unavailable` otherwise: `EXA_API_KEY` (claim verification), `MOBSF_URL` + `MOBSF_API_KEY` (deeper APK analysis, only with `consent_external_upload`), `OPENAI_VISION_MODEL` (image vision pass; OCR runs regardless).

Expired uploads are removed by a background task in `analysis-service` (`RETENTION_ENABLED`, `RETENTION_INTERVAL_SECONDS`) that deletes the Storage object and then the `files` row; the same code path is reachable through `POST /internal/v1/maintenance/retention`.

`go-api` reads Postgres through **pgx with the simple query protocol** when `DATABASE_URL` is set (transaction pooler compatible) and falls back to PostgREST when it is empty, so the stack keeps working without a direct database DSN.

## Fase 4: scoring, monitoring, dynamic analysis, hardening

- **Kalibrasi skor** (`analysis-service/app/risk.py`): `risk.score` is now a calibrated 0–100 number instead of `null`. Each finding contributes `severity × source × confidence`; independent evidence is combined multiplicatively so one weak model finding cannot produce a high score, while several medium findings can. A single-source rule caps the score at 60, so `checks_unavailable` is never hidden by a confident-sounding number. `low` is only reported when at least three independent positive checks ran clean — otherwise the level stays `unknown`.
- **Monitoring**: internal `GET /internal/v1/metrics` on both services (service key required). The analysis service reports job counters by type/status, job latency, agent runs, tool calls per tool, external retries and retention runs; the Go API reports `scans_created`, `scans_failed`, `jobs_completed`, `jobs_failed`, `scan_timeouts`, `auth_failures` and the active data store (`pgx` or `postgrest`).
- **LangGraph kondisional lanjutan**: the URL graph now runs one bounded deep-check pass (`MAX_DEEP_TARGETS=2`) against cross-domain form actions and the redirect destination, merging prefixed findings without opening a second browser session.
- **Dynamic APK analysis** (`analysis-service/app/dynamic.py`): optional client for an operator-provided sandbox (`DYNAMIC_ANALYSIS_URL`, `DYNAMIC_ANALYSIS_API_KEY`), consent-gated like the other external uploads. ThreatLens does not ship an emulator, so when the sandbox is absent the scan records `dynamic_analysis` as unavailable instead of claiming runtime coverage.
- **Hardening**: the Next.js app sends CSP, HSTS, `nosniff`, `Referrer-Policy`, `frame-ancestors 'none'` and a Permissions-Policy (`frontend/next.config.ts`); Python logs pass through a redacting filter (`analysis-service/app/logs.py`) that masks API keys, JWTs, 64-hex secrets, bearer tokens and database URLs; job execution is bounded by `MAX_CONCURRENT_JOBS`.

## Deteksi domain mirip brand (lookalike)

`analysis-service/app/brand_guard.py` membandingkan setiap host dengan daftar brand resmi di `analysis-service/app/data/brands.json` (80 brand: bank/e-wallet/e-commerce Indonesia, logistik, dan layanan global). Deteksinya deterministik dan offline:

| Teknik | Contoh | Level |
|---|---|---|
| Substitusi karakter | `g00gle.com`, `paypa1.com` | high |
| Typosquatting | `goggle.com`, `gooogle.com` | high |
| Homograph / punycode | `xn--80ak6aa92e.com`, `gооgle.com` | high |
| Nama brand disisipkan | `bca-login.xyz`, `shopee-promo.click` | high |
| Brand di bawah domain lain | `google.com.secure-login.xyz` | high |
| Brand sebagai subdomain | `login.google.security-check.xyz` | medium |
| Brand di TLD lain | `bca.com` | medium |

Yang diperiksa: host URL awal, host akhir setelah redirect, host form action lintas-domain, tautan yang diekstrak dari pesan/gambar, dan domain hardcoded di APK. Domain resmi (`google.com`, `mail.google.com`, `bca.co.id`) tidak ditandai. Daftar bisa diganti lewat `BRAND_ALLOWLIST_PATH` tanpa ubah kode.

Batasannya: ini menandai **kemiripan nama**, bukan membuktikan halaman berbahaya — jadi hasilnya paling tinggi `suspicious/high`, tidak pernah `confirmed_threat`. Pemakaian domain resmi untuk phishing (mis. halaman jahat di layanan sah) dan domain acak tanpa kemiripan brand tidak tertangkap di sini.

## Google OAuth

Create a Google OAuth Web client in Google Cloud Console. Add `https://<project-ref>.supabase.co/auth/v1/callback` to Google's **Authorized redirect URIs**. Put its client ID/secret in `infra/supabase/.env`. Run from the workspace root:

```powershell
Set-Location infra
.\supabase\apply-auth-config.ps1 -Preview
.\supabase\apply-auth-config.ps1
```

Supabase's site URL and allowed callback URL are `http://localhost:3000` and `http://localhost:3000/auth/callback`.

## Checks

```sh
(cd backend && go test ./...)
(cd analysis-service && python -m pytest)
(cd frontend && npm run lint && npx tsc --noEmit && npm run build)
docker compose -f infra/docker-compose.yml config --quiet
```
