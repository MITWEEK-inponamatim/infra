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
   $worker = @("FILE_WORKER_SERVICE_KEY=$(New-DerivedKey 'threatlens-file-service')", 'WORKER_MAX_CONCURRENCY=2', 'WORKER_MAX_BODY_MB=52', 'WORKER_APK_TIMEOUT_SECONDS=150')
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

    The URL scanner runs Chromium in an isolated, non-root worker with CPU, memory, and process limits. Container Chromium sandbox is disabled because Docker Desktop lacks unprivileged user namespaces; the worker has no direct internet or backend network access, and all browser egress goes through a DNS-pinning proxy that allows only public HTTP/HTTPS on ports 80/443. The file scanner (`analysis-worker`) handles APK static analysis in a non-root container with a read-only root filesystem, CPU/memory/pid limits, and no internet route at all. Both read derived keys from `analysis-service/.env.browser` and `analysis-service/.env.worker`, which step 5 writes; **`analysis-worker` refuses to start while `FILE_WORKER_SERVICE_KEY` is empty** and prints the fix in its logs. Apply `infra/supabase/migrations/202610300002_langgraph_schema.sql` in the hosted SQL Editor, then set `DATABASE_URL_SESSION` in `analysis-service/.env` to enable LangGraph checkpoints. Without it, URL analysis still runs but reports checkpointing as unavailable.

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
| `analysis-worker` | Isolated APK static analysis (no internet network, non-root, read-only rootfs, CPU/mem/pid limits) |

`analysis-worker` exposes `POST /internal/v1/analyze/application`, guarded by the derived `FILE_WORKER_SERVICE_KEY`. It only extracts evidence; every risk decision stays in `analysis-service/app/apk_rules.py` and `app/risk.py`.

Phase 3 scanners:

- **Phone** — `phonenumbers` normalisation to E.164 for **Indonesian numbers only** (`+62`), premium-rate detection, community lookups in `phone_reports`, and the reviews of that number shown as "Kata warga". A valid number is never reported as "safe".
- **Application** — SHA-256 hash reputation (VirusTotal when configured), zip-bomb pre-check (entry count, per-entry size, total uncompressed size, compression ratio), Androguard static extraction, and deterministic combination rules (SMS + accessibility/overlay/install capability, embedded Telegram bot token, hidden launcher icon, packer hints). The APK is never executed and is only uploaded to VirusTotal when the user ticks `consent_external_upload`.

Unavailable checks are reported per scan in `risk.coverage.checks_unavailable` instead of failing the scan.

## Laporan komunitas nomor telepon

`POST /api/v1/phone-reports` (authenticated, **multipart**) stores user reports, and `POST /internal/v1/phone/normalize` (service key) is the single normalisation implementation: the Go API stores the E.164 value Python computed instead of keeping a second copy of the rules. The write path lives in Go because the user identity lives there.

| Bagian | Detail |
|---|---|
| Body laporan | multipart: `number`, `default_region`, `category`, `note?`, **`evidence` (wajib)** |
| Cakupan | Indonesian numbers only. `default_region` is validated as `ID`, and the parsed country code must be `+62` — a `+1`/`+65` number submitted with `default_region: "ID"` is still rejected (`400 not_indonesian`) because scope comes from the number, not from the field |
| Kategori | closed vocabulary: `penipuan`, `phishing`, `pharming`, `spam`, `telemarketing`, `penagih_utang`, `peniruan_identitas`, `lainnya`. Yang lima pertama adalah kategori papan, karena form laporan di `/community/phone` mengirim kategori yang sama seperti cerita; tiga sisanya tetap diterima karena `/recognize` masih menawarkannya. Tidak ada `check` di kolom ini, perluasan vocabularies tidak butuh migrasi |
| Status awal | `pending` — a report never raises risk by itself |
| Dedup | one report per account per number (unique index `phone_reports_reporter_number_key`) → `409 duplicate_report` |
| Rate limit | `PHONE_REPORT_HOURLY_LIMIT` (default 10/hour per account, in-process) |
| Catatan | `note` is capped at 280 characters, moderation-only, never sent to an LLM and never shown to other users |
| Moderasi | `PATCH /internal/v1/phone-reports/{id}` (service key) → `verified`, `rejected`, `rejected_spam`, `pending` |
| Bukti gambar | wajib, satu berkas per laporan. `MAX_EVIDENCE_MB` (default 5) membatasi ukuran; tipe dicek dari **magic byte**, bukan ekstensi: `png`, `jpeg`, `webp`, `heic`/`heif` diterima, `gif` dan selain gambar ditolak (`400 evidence_unsupported_type`) |
| Bila penyimpanan bukti gagal | laporan **ditolak** (`503 evidence_unavailable`) dan tidak ada baris database yang masuk — "bukti wajib" tidak boleh diam-diam berubah jadi anjuran |

Validity is deliberately **not** a gate for reporting: normalisation is a search key, so a `+62` number the library cannot confirm as a real subscriber is still stored as `pending` (the community, not a length rule, decides whether it is a scammer). Detection itself refuses to look up anything outside `+62`, and the checker says so instead of returning an empty "clean" verdict.

`phone_scanner.review_cards` puts the reviews of the checked number into `report.artifacts.community_reviews` (`category`, `status`, `age_days`) — up to 20, pending and verified only, and `reported_by` never leaves the server. The UI renders it as "Kata warga" under the phone result.

The trust summary in `analysis-service/app/phone_scanner.py::summarize_reports` is explainable: number of reports, verified reports, distinct reporters, categories, and recency. `high` requires at least two verified reports from two different reporters, so one account repeating itself never reaches `high`. The scan report always keeps the spoofing/number-reuse/report-error limitations, and the UI shows a "Laporkan nomor ini" panel under the phone result.

Apply `infra/supabase/migrations/202610300004_phone_reports_trust.sql` and `infra/supabase/migrations/202610300005_phone_reports_note.sql` in the hosted SQL Editor. Without `0004` duplicates are only caught by the application check; without `0005` the report is still stored and returns `note_saved: false`.

For the mandatory evidence image, also apply `infra/supabase/migrations/202611040006_phone_reports_evidence.sql` (adds `evidence_url` + `evidence_public_id`). Until that migration is run every report is refused with `503 service_unavailable` and the uploaded image is deleted again — nothing is stored without its proof.

Deliberately **not** implemented: owner-name lookup (Truecaller-style) and any GetContact integration. Both require an account or credentials for a third-party service whose terms forbid it, and they would store other people's personal data without a lawful basis. The product reports "other people flagged this number", never "this number belongs to X".

## Board komunitas `/community`

Board where residents tell what happened with one `+62` number, dressed in the visual language of a photo feed rather than of this product's landing page. Six authenticated routes in `backend/community.go`: `POST`/`GET /api/v1/community/posts`, `GET /api/v1/community/posts/{postID}`, `POST …/{postID}/vote`, `POST …/{postID}/comments`, `GET /api/v1/community/dangerous-numbers`.

| Bagian | Detail |
|---|---|
| Kategori | closed vocabulary of five: `penipuan`, `phishing`, `pharming`, `spam`, `peniruan_identitas` (telemarketing and debt collection belong to `spam`) |
| Isi | judul 4–120 karakter, cerita 10–4000 karakter, nomor `+62` saja (bentuk `^\+62[0-9]{8,20}$`) |
| Bukti gambar | **wajib**, jalur yang sama dengan laporan (`/internal/v1/phone-reports/evidence`, folder `threatlens/phone-reports/`), tanpa folder Cloudinary baru |
| Identitas penulis | `author_alias` = `Warga-` + 6 hex pertama HMAC-SHA256 (`PRE_COOKIE_SECRET`) atas user id; `author_user_id` tidak pernah ikut keluar ke browser |
| Vote | satu suara per akun per cerita (`community_votes` PK `(post_id, user_id)`), value `1`/`-1`/`0` (cabut suara), lewat RPC `cast_vote` karena satu statement tetap aman dari race tanpa transaksi |
| Efek vote | **hanya urutan feed.** Tidak mengubah risiko, level, atau daftar "Nomor berbahaya" |
| Komentar | dua tingkat saja; balasan ke balasan ditolak `400 reply_too_deep`, dan parent harus berada di post yang sama |
| Rate limit | `COMMUNITY_POST_HOURLY_LIMIT` 6/jam, `COMMENT_MINUTE_LIMIT` 5/menit, `COMMENT_HOURLY_LIMIT` 20/jam, `VOTE_LIMIT_PER_MINUTE` 30/menit (semua in-process, ada default di kode) |
| Tab ketiga | membaca view `dangerous_numbers`, yang ambangnya identik dengan aturan `high` di `phone_scanner.summarize_reports` (≥2 laporan terverifikasi dari ≥2 pelapor) — sumbernya tetap `phone_reports`, bukan post |

Frontend: `frontend/src/components/community/*`. The board has its own shell — `CommunityShell`, a 60px white bar over a `#fafafa` canvas with `#dbdbdb` hairlines — and not `SiteShell`, because a feed is read while a landing page is looked at. Type is the **system stack** (`--font-pos-ui` in `app/globals.css`): no webfont is fetched for the board, so `font-src 'self'` is never exercised and the first paint has no swap. Its palette is the `--color-pos-*` block in `app/globals.css` (`shell`, `card`, `line`, `ink`, `muted`, `action`, `action-tua`, `flag`, `good`, `bad`); the landing page and `/recognize` touch none of it, and the blue is `#0095f6` for fills only — text uses `action-tua` because `#0095f6` on white is only ~3:1.

Layout follows a photo feed: each tab is its own address — `/community/latest` (Terbaru), `/community/popular` (Terpopuler), `/community/phone` (Nomor berbahaya) — and `/community` forwards to `latest` with `?nomor=` riding along, because a tab somebody means to share or come back to has to be something a link can point at. `CommunityBoard` is three columns at `xl` (244px tab rail / **470px** feed / 340px notes), the feed keeps that measure on every wider screen, and below `lg` the rail becomes a fixed four-item bottom bar. A post is header (alias disc, number, `alias · waktu`, category chip) → evidence on a dark stage → action row → tally line → caption (bold opening phrase, then the excerpt) → "Lihat semua N komentar". `PostThread` is the same post opened as a permalink: two panes at `lg` (media stage / scrollable comments with a pinned composer at the bottom). `CreatePostPanel` is a modal, not a page.

The fourth slot in both the rail and the bottom bar is **the action of the tab you are on**, and the two actions are not the same thing: on `latest`/`popular` it is "Cerita baru", which opens the story composer inside this board; on `phone` it is "Lapor nomor berbahaya", which opens the report form — `ReportNumberPanel` — in that same page. Nothing leaves the board, and nothing pretends the two acts are alike: the composer posts a `community_posts` row that only ever re-sorts a feed, while the report posts to `POST /api/v1/phone-reports` (the same endpoint the scan page uses, evidence image still mandatory) and waits for moderation, because only verified reports can put a number on that list. `/community/phone` therefore has no composer button at all, and `/recognize` keeps its own report form for somebody who arrived from a scan.

Two devices carry the product's meaning, so they are not decorative: the **number is the handle** — every row leads with `+62 812-3456-7890` in bold, linking to `/recognize/phone/[slug]` (`NumberHandle`), because the number is the one fact all witnesses agree on and the writer is only a witness; and the **gradient ring** (`NumberAvatar`) means exactly one thing — that number crossed the verified-report threshold — so it appears only in the "Nomor berbahaya" list. Nav and vote icons switch outlined → filled instead of changing colour. Votes are up/down arrows in a 44px round target with the score exposed to screen readers only; the visible tally is the feed-style "24 menganggap berguna · 2 menganggap tidak" line.

Components: `CreatePostPanel`, `ReportNumberPanel`, `PostCard`, `VoteControls`, `CategoryChip`, `DangerousNumberList`, `NumberHandle`, `CommunityShell`, `BoardPage` (the auth + shell + Suspense plumbing the three tab pages share); data in `hooks/useCommunity.ts`, labels and helpers in `lib/community.ts`. Every community address requires login (`src/proxy.ts` guards everything except `/`, `/login`, `/auth/callback`; `lib/paths.ts` keeps the story id, the number page, and the three tab addresses through the login round-trip).

Cerita warga **bukan** bukti dan **bukan** vonis: post tidak pernah menaikkan level risiko sebuah nomor, dan satu cerita yang benar belum pasti tentang orang yang sama — nomor bisa dipalsukan dan berpindah pemilik. Batasan itu ditulis di UI, bukan hanya di dokumen ini.

`infra/supabase/migrations/202611040007_community_posts.sql` has been applied in the hosted SQL Editor (2026-11-04). On a database without those tables the board fails closed instead of lying: every list and the dangerous-numbers tab answer `503 service_unavailable`, and a new post is refused after its image is uploaded (the image is deleted again, so no story exists without its proof).

## Bukti gambar di Cloudinary

Gambar bukti dikirim Go ke analysis-service sebagai **base64 dalam JSON** (`POST /internal/v1/phone-reports/evidence`), bukan multipart: Go tidak punya pasangan multipart untuk SDK Python, dan 5 MiB = 5.242.880 byte → 6.990.508 karakter base64, masih di bawah batas skema 7.000.000.

- Aset masuk ke folder `threatlens/phone-reports/<user_id>/<report_id>-<8 byte acak>`; suffix acak membuat URL bukti tidak bisa dijelajahi, dan `discard()` menolak public_id di luar folder itu — screenshot scanner di `threatlens/scans` tak tersentuh.
- `reported_by` tidak pernah keluar dari server. URL gambar boleh tampil, identitas pelapor tidak.
- Penghapusan memakai `destroy(..., invalidate=True)`. Terbukti live: tanpa `invalidate` CDN tetap menyajikan gambar `200` setelah aset dihapus, dengannya URL yang sama jadi `404` dalam ≤30 detik.
- Endpoint bukti hanya menerima service key, dan kegagalannya selalu berbunyi `503 evidence_unavailable` — tidak pernah mengembalikan URL kosong.

**Jejebakan konfigurasi:** SDK Cloudinary membaca `CLOUDINARY_URL` hanya **kalau `CLOUDINARY_CLOUD_NAME` tidak ada** (`Config._load_config_from_env`). Proyek ini mengatur keduanya, jadi `cloudinary.config(cloudinary_url=...)` dulu menghasilkan config **tanpa api_key/api_secret** dan upload gagal. Sekarang `_configure()` mengurai URL sendiri: `api_key`/`api_secret` dari URL, `cloud_name` dari `CLOUDINARY_CLOUD_NAME` dengan fallback ke host URL. Host di `CLOUDINARY_URL` deployment ini (`dlwbthmsn0`) tidak valid — nama cloud yang benar `wbthmsn0`. `app/browser_client.py` (screenshot scanner) punya bug yang sama dan sudah diperbaiki; sebelumnya kegagalan upload screenshot tertelan senyap.

## Halaman hasil deteksi nomor

Tab **Telepon** di `/recognize` adalah kotak pencarian sekaligus tempat prosesnya berjalan: tekan enter atau tombol **Cari**, animasi loading muncul di situ, dan halaman baru **hanya dibuka setelah hasilnya ada**. Hasilnya tidak dihitung ulang di tujuan — `frontend/src/lib/phoneHandoff.ts` menyimpan verdict yang barusan selesai (dibatasi 20 entri, dibaca tanpa dihapus supaya effect yang dijalankan dua kali di dev tidak memicu scan kedua) dan `/recognize/phone/[nomor]` mengambilnya dari sana. Kalau datang lewat bookmark, tautan orang lain, atau refresh — tidak ada yang di-handoff — baru halaman itu memeriksa sendiri.

Slug selalu bentuk kanonik: `0812…`, `62812…`, `+62 0812…` → `62812…`; URL non-kanonik di-`redirect()` ke slug kanonik, jadi satu nomor hanya punya satu alamat.

`0` setelah `62` dibuang di ketiga bahasa (Python, Go, TypeScript): nomor pelanggan Indonesia tidak pernah diawali `0` sesudah +62. Aturan UI-nya **9–12 digit** setelah `+62`.

Halaman ini Partial Prerendering, jadi `await params` harus berada **di dalam** `<Suspense>`; di luarnya, `next build` gagal dengan "encountered uncached or runtime data during prerendering".

## Halaman hasil ber-id scan dan riwayatnya

Hasil pemeriksaan **tautan** dan **APK** pindah ke alamat sendiri setelah verdict tiba: `/recognize/url/<scan_id>` dan `/recognize/apk/<scan_id>`. Loading tetap di `/recognize` (`useScanner` menyimpan `runningKind` untuk tahu tujuan yang benar), dan perpindahan baru terjadi di poll yang sama yang menampilkan hasilnya.

Berbeda dari nomor, halaman ini **tidak** menerima handoff dari memori: `ScanRecordResult` membaca ulang `GET /api/v1/scans/<id>` (satu read pertama tanpa header, sisanya `X-Activity: passive`), jadi bookmark, refresh, dan baris riwayat semuanya membuka halaman yang sama tanpa memeriksa ulang apa pun. Kalau statusnya belum final, halaman itu poll 2,5 detik sampai final. `input_ref` yang disimpan APK berbentuk `<user_id>/<scan_id>/<nama berkas>` — yang ditampilkan hanya segmen terakhir, nama berkas yang diunggah; isi APK-nya tidak pernah disajikan di UI.

`/history` adalah daftarnya: `GET /api/v1/scans?type=url,application&limit=20&offset=<n>`, urut terbaru, tiap baris menaut ke halaman hasilnya. Pemeriksaan **nomor sengaja tidak masuk riwayat** karena jawabannya sudah menempel di halaman nomornya — tidak ada alamat ber-scan-id untuk jenis itu (`scanResultPath()` mengembalikan `null`, barisnya tetap tampil tapi tidak bisa diklik kalau suatu saat tipe lain muncul). Filter `?type=` divalidasi `scanTypeFilter()` terhadap tiga tipe yang benar-benar disimpan; nilai asing → `400 invalid_request`, bukan tembus ke query. Halaman baru ini juga harus didaftarkan di `safeNext()` (`SCAN_RESULT`), sonst round-trip login membuangnya ke `/recognize`.

## Analysis pipeline (graphs, tools, retention)

Every scanner now runs through its own LangGraph state graph in `analysis-service/app/graph/` (`url`, `phone`, `application`) with explicit nodes, conditional edges, and a bounded follow-up (URL redirect host change). `DATABASE_URL_SESSION` enables the `PostgresSaver`; when it is empty the graphs still run and report `langgraph_checkpointer` as unavailable.

The LLM can only call the eight whitelisted tools in `analysis-service/app/tools.py` (`check_url_reputation`, `inspect_website`, `get_page_metadata`, `inspect_forms`, `analyze_application`, `lookup_phone`, `analyze_message`, `search_verification_evidence`). Tools take a `scan_id`/`file_id`, never a path or arbitrary URL, every argument is validated in code, and evidence always comes from what the deterministic pipeline already collected.

Bounded by design:

```sh
AGENT_TOOL_ROUNDS=2        # max tool-calling rounds per LLM pass
AGENT_MAX_TOOL_CALLS=6     # max executed tool calls per scan
EXTERNAL_RETRY_ATTEMPTS=3  # retry/backoff for transient external failures (timeouts, 429, 5xx)
```

Optional integrations stay inert until configured; each one is reported in `checks_unavailable` otherwise: `EXA_API_KEY` (claim verification), `MOBSF_URL` + `MOBSF_API_KEY` (deeper APK analysis, only with `consent_external_upload`).

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

Yang diperiksa: host URL awal, host akhir setelah redirect, host form action lintas-domain, dan domain hardcoded di APK. Domain resmi (`google.com`, `mail.google.com`, `bca.co.id`) tidak ditandai. Daftar bisa diganti lewat `BRAND_ALLOWLIST_PATH` tanpa ubah kode.

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
