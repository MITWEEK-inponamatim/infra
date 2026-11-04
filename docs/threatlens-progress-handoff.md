# ThreatLens Progress Handoff

Dokumen ini melengkapi spesifikasi utama di `threatlens-handoff.md`. Baca keduanya sebelum lanjut.
Terakhir diperbarui: 2026-11-04 setelah P0b nomor telepon (bukti gambar wajib ke Cloudinary, kunci kanonik +62 tanpa `0` redundan, halaman `/recognize/phone/[nomor]` dengan loading tetap di `/recognize`) selesai di kode dan diverifikasi di Docker. Migration `202611040006` sudah dijalankan user. P1 belum dimulai dan **harus dikonfirmasi dulu**.

## Workspace empat repo (2026-10-31)

- `D:\mitweek` adalah workspace lokal, bukan repo Git. `infra/` berisi Compose, Supabase, README, dan handoff docs; `frontend/`, `backend/`, `analysis-service/` adalah folder layanan sejajar.
- Jalankan Compose dari workspace root: `docker compose -f infra/docker-compose.yml ...`. Compose project name dipatok `mitweek` agar cocok dengan container stack yang sudah ada.
- Supabase config/migrations dan env lokal berada di `infra/supabase/`. File `.env` dipindah tanpa dicetak; `.gitignore` infra mengecualikannya.
- Setiap repo layanan punya `.gitignore` sendiri; belum ada `git init`, commit, remote, atau push. User akan melakukan commit/push manual.

## Status sekarang

- Fase 1 tersedia dan user mengonfirmasi scan URL, Riwayat, ownership isolation, serta server logout. (Scan pesan dan tangkapan layar sudah dihapus 2026-11-03 — lihat catatan paling bawah; deteksi tersisa: URL, APK, nomor telepon.)
- **Fase 2 selesai**: Browser Intelligence berjalan di Compose; browser worker terisolasi dan hanya egress proxy yang punya akses internet.
- Google OAuth sudah dikonfigurasi user di Google Cloud dan Supabase Dashboard. User mengonfirmasi login berhasil setelah callback diperbaiki.
- Migrasi `infra/supabase/migrations/202610300001_initial_schema.sql` sudah dijalankan manual melalui Supabase SQL Editor. Endpoint PostgREST mengonfirmasi `public.scans` tersedia. Jangan jalankan ulang file SQL seluruhnya; migrasi pernah diterapkan manual dan CLI migration history belum disinkronkan.
- Google OAuth berstatus development/testing. Hanya akun yang dimasukkan sebagai Google OAuth Test User yang dapat login.
- User memakai hosted Supabase. `DATABASE_URL` dan `DATABASE_URL_SESSION` kosong; `DATABASE_URL_SESSION` diperlukan untuk mengaktifkan LangGraph PostgresSaver.
- `.env` ada terpisah di `frontend/`, `backend/`, `analysis-service/`, `analysis-service/.env.browser`, dan `infra/supabase/`. Isinya rahasia, masuk `.gitignore`; **jangan baca/cetak/tulis nilainya ke laporan**. Jangan minta user mengirim secret di chat.
- `analysis-service/.env.browser` berisi `BROWSER_SERVICE_KEY` turunan dan `BROWSER_MAX_RESPONSE_MB`, bukan secret backend lain. Dibuat lokal dengan prosedur README; file ini tidak dicommit.
- `analysis-service/.env.worker` berisi `FILE_WORKER_SERVICE_KEY` turunan (domain HMAC `threatlens-file-service`) untuk container `analysis-worker`. Wajib ada sebelum `docker compose up`; prosedur pembuatannya ada di README langkah 5 dan tidak mencetak nilai kunci.
- Jangan minta user mengirim secret di chat.

## Fase 3 (selesai dan diverifikasi lewat Docker)

- Phone scanner nyata: `analysis-service/app/phone_scanner.py` (normalisasi `phonenumbers` → E.164, deteksi premium rate, fallback deterministik bila library tidak ada), membaca `phone_reports` lewat PostgREST, selalu menuliskan keterbatasan spoofing/pindah pemilik/laporan keliru. Nomor valid tidak pernah dilaporkan "aman".
- Image scanner: `app/image_scanner.py` + `app/image_extract.py` (OCR `ind+eng`, batas format/piksel) → pipeline pesan → maksimal 2 URL lewat URL scanner; semua temuan URL diberi prefiks host.
- Application scanner: `app/apk_scanner.py`, `app/apk_extract.py`, `app/apk_rules.py`. Hash SHA-256 diverifikasi ulang, lookup VirusTotal opsional, upload sampel hanya bila `consent_external_upload`, pre-check zip bomb (jumlah entry, ukuran per entry, total dekompresi, rasio), ekstraksi Androguard, aturan kombinasi deterministik (SMS + accessibility/overlay/install, klaim brand + kemampuan kontrol, token bot Telegram, ikon launcher tersembunyi, indikasi packer). APK tidak pernah dijalankan.
- Worker terisolasi baru: `app/file_worker.py`, `Dockerfile.worker`, `requirements.worker.txt`, layanan `analysis-worker` di Compose (network internal tanpa internet, non-root, read-only rootfs + tmpfs, batas CPU/memori/pid, timeout per jenis). Klien: `app/file_client.py` (fallback in-process saat `FILE_WORKER_URL` kosong, mis. tes lokal).
- Storage: `app/storage.py` memverifikasi path `{user_id}/{scan_id}/...` sebelum unduh dari bucket private.
- Go: scan phone/image/APK sekarang diteruskan ke analysis service (`processScan`) dengan input `{bucket, storage_path, sha256, size_bytes, mime, filename}` dan `options.consent_external_upload`; batas unggah gambar 15 MB (`MAX_IMAGE_MB`), APK 50 MB, serta budget polling lebih panjang untuk APK (`SCAN_APPLICATION_TIMEOUT_SECONDS`, default 180 s).
- Risk engine: `fail_report()` baru supaya job yang crash tetap mengembalikan laporan `scan_failed`, dan `assess()` menerima `limitations`/`artifacts`/`confidence`.
- Frontend: form tidak diubah strukturnya. Hanya pemetaan pesan error per kode (termasuk `file_too_large`, `unsupported_file_type`, `rate_limited`, sesi berakhir), validasi ringan nomor 7–15 digit, dan teks persetujuan APK disesuaikan agar akurat (hash selalu diperiksa, sampel hanya dikirim bila disetujui).
- Tes: `analysis-service` **128 passed** (LangGraph kini terpasang di `.venv` lokal), termasuk tes tools/agent/graph/retention/resilience serta tes lama; `backend` `go test ./...` lulus termasuk tes fallback store, dan `npm run lint` + `tsc --noEmit` bersih.
- Verifikasi lewat Docker di sesi ini: build `analysis-worker`, `go-api`, `analysis-service`, `frontend` sukses (termasuk `npm run build`). Smoke di image: `capabilities` benar, graph pesan menghasilkan temuan tanpa duplikat + `url_scan`, graph telepon memberi `insufficient_evidence` dengan confidence low, URL tanpa browser worker melaporkan `browser_inspection` unavailable. Worker: OCR `ind+eng` membaca teks uji, APK rusak ditolak, 401 tanpa kunci.
- Ada bug yang ditemukan lewat smoke ini dan sudah diperbaiki: temuan heuristik sempat dobel karena graph dan helper sama-sama menambahkannya; kini heuristik hanya dibuat node graph (`test_heuristic_findings_are_not_duplicated`).


## Service dan port

- Docker Compose ThreatLens berjalan: frontend `http://localhost:3000`, Go API `http://localhost:8080`; analysis, browser gateway, worker, dan egress proxy hanya pada network internal.
- Sebelumnya Docker Compose gagal bind `3000`, lalu mapping dipindah ke `3001`. User sudah membebaskan port tersebut; Compose dan README sekarang memakai `3000`.
- Supabase lokal sudah dihentikan; target adalah hosted Supabase.
- Windows PostgreSQL (`5432`) dan MongoDB (`27017`) terdeteksi sebagai services, tetapi tidak dapat dihentikan karena sesi PowerShell tidak Administrator. Ollama pernah dihentikan tetapi dapat restart sendiri. Hindari menghentikan proses lain tanpa identifikasi/konfirmasi.
- Enam service Compose sehat/berjalan: `frontend`, `go-api`, `analysis-service`, `browser-gateway`, `browser-worker`, `browser-egress`. `/login` dan `/api/v1/health` merespons HTTP 200.

## Perbaikan OAuth terbaru

- Akar masalah yang paling mungkin: pertukaran authorization code dilakukan dari client effect dan bisa terulang; satu proses berhasil membuat session, proses lain menerima code-used error.
- Callback dipindah ke `frontend/src/app/auth/callback/route.ts`. Route Handler menukar code sekali, meneruskan cookies ke Go `finalize`, lalu redirect. Go internal URL untuk container memakai `INTERNAL_API_BASE_URL=http://go-api:8080`.
- Rebuild Compose sukses. User kemudian mengonfirmasi login berhasil.

## Modul utama yang sudah dibuat

- Frontend: `frontend/src/proxy.ts`, `frontend/src/lib/supabase/*`, login, callback server-side, idle monitor, scan/history, API helper.
- UI: `frontend/src/components/recognize/RecognizeCard.tsx` dikembalikan ke desain awal hero/card; tab nomor telepon tetap ditambahkan.
- Go: `backend/main.go` berisi routing, JWT/JWKS verification, Turnstile, sesi, scan/upload/history, komunikasi Python.
- Python: `analysis-service/app/main.py`, `scanners.py`, `llm.py`, `risk.py`, `schemas.py`; service-key auth dan job async.
- Browser: `browser_worker.py`, DNS/IP request guard, DNS-pinning egress proxy dengan batas request/byte/konkurensi, gateway internal, Playwright evidence, screenshot upload ke private Storage.
- URL graph: `analysis-service/app/url_graph.py`; LangGraph graph validasi kondisional. `langgraph-checkpoint-postgres` dan schema migrasi sudah disiapkan.
- Browser files: `analysis-service/app/browser_guard.py`, `browser_worker.py`, `browser_gateway.py`, `pinned_proxy.py`, `egress_proxy.py`, `browser_client.py`, `browser_auth.py`, `run_browser_worker.py`.
- Container/network: `analysis-service/Dockerfile.browser`, `Dockerfile.egress`, `Dockerfile.gateway`; dedicated internal networks. Browser worker tidak mendapat akses langsung ke backend/internet; proxy melakukan DNS resolution, reject non-public IP, lalu connect ke IP hasil resolusi.
- Screenshot disimpan di private bucket `scan-artifacts` pada path `{user_id}/{scan_id}/page.png`; metadata masuk `files`. Upload/metadata failure ditangani sebagai artifact unavailable.
- Supabase: migrasi skema, RLS, storage buckets/policies di `infra/supabase/migrations/202610300001_initial_schema.sql`.
- Env: `.env.example` per frontend/backend/analysis-service/Supabase; root `.env.example` dihapus. Hanya commit `.env.example`.
- Setup/config: `infra/docker-compose.yml`, Dockerfile tiap service, `infra/README.md`, `infra/supabase/apply-auth-config.ps1` (opsional; OAuth sudah dikonfigurasi manual lewat Dashboard).
- Handoff spek mendapat tambahan Application scanner 7.5a dari user.

## Pemeriksaan yang lulus

- `cd backend; go test ./...`
- `cd analysis-service; python -m pytest -q` — 37 passed, 1 skipped di Python lokal (LangGraph tidak terpasang lokal).
- Test dalam image `analysis-service` yang memuat LangGraph: 39 passed; 1 warning dependency LangGraph.
- `cd frontend; npm run lint; npx tsc --noEmit`
- `docker compose -f infra/docker-compose.yml up --build -d` — image frontend, Go, Python berhasil dibangun.
- `docker compose -f infra/docker-compose.yml ps` — enam service sehat.
- Frontend `/login` dan Go `/api/v1/health` memberi HTTP 200.
- Supabase OAuth authorize URL mengarah ke Google.
- User mengonfirmasi Google login berhasil setelah perbaikan callback.
- User mengonfirmasi scan pesan, scan URL end-to-end, dan Riwayat berfungsi.
- User mengonfirmasi scan/file ownership isolation lewat query Supabase dengan sesi user, serta server logout session berfungsi.
- `docker compose -f infra/docker-compose.yml config --quiet` dan `docker compose -f infra/docker-compose.yml up --build -d` lulus; enam service berjalan sehat.
- Browser worker membuka `https://example.com/` di container: title, visible text, redirect chain, screenshot berhasil.
- Smoke hasil: HTTP 200, title `Example Domain`, visible text 917 karakter, screenshot base64 93,548 karakter.
- Tes browser guard mencakup private/reserved IPv4/IPv6, localhost, cloud metadata, skema/port terlarang, DNS campuran, egress pinning, redirect ke loopback (mock), proxy auth, byte/request limits.

## Kerangka lanjutan yang sekarang ada (bekas celah "belum", sudah dikerjakan)

- **Tool calling whitelist (§7.3)**: `analysis-service/app/tools.py` — 9 tool sesuai spesifikasi, semua argumen divalidasi di kode (scan_id harus cocok, file_id harus milik scan itu, URL harus publik, region nomor dari allowlist, panjang teks/klaim dibatasi). Tool hanya membaca evidence yang sudah dikumpulkan (tidak membuka browser/URL baru) dan setiap panggilan dicatat di `ToolContext.calls` (audit trail).
- **Batas iterasi (§7.2)**: loop tool dibatasi `AGENT_TOOL_ROUNDS=2` dan `AGENT_MAX_TOOL_CALLS=6` di `app/agent.py`; graph juga membatasi follow-up (URL: 1 putaran redirect; pesan/gambar: 1 putaran URL).
- **Satu graph per scanner (§7.2)**: paket `app/graph/` (`url`, `message`, `phone`, `image`, `application`, `runner`). URL graph pindah ke `graph/url.py`; `app/url_graph.py` tinggal shim. Node = langkah deterministik, edge kondisional, dan `PostgresSaver` dibuka lewat `graph/runner.py` saat `DATABASE_URL_SESSION` diisi (tanpa itu graph tetap jalan dan melaporkan `langgraph_checkpointer`).
- **Message → URL scanner (§7.5)**: graph pesan mengekstrak URL (maks `MESSAGE_URL_SCAN_LIMIT`, default 2), menjalankan URL scanner, dan memberi prefiks host pada temuan. Gambar memakai jalur yang sama.
- **Retry + backoff (§7.2)**: `app/resilience.py` (timeout/koneksi/408/425/429/5xx, exponential backoff, `EXTERNAL_RETRY_ATTEMPTS=3`) dipakai Safe Browsing, VirusTotal, Storage, laporan komunitas, browser client, worker client, Exa, dan MobSF.
- **Exa (§7.5, opsional)**: `app/exa.py` + tool `search_verification_evidence`; tanpa `EXA_API_KEY` hasilnya `{"available": false}` dan tercatat `checks_unavailable`.
- **OpenAI vision (§7.5, opsional)**: `app/vision.py`; hanya aktif bila `OPENAI_VISION_MODEL` diset, input dibatasi `VISION_MAX_MB=4`, temuan ber-label `llm_vision`.
- **MobSF/JADX (§7.5a, opsional)**: `app/mobsf.py` (upload → scan → report_json, diringkas); hanya dipakai bila `MOBSF_URL` + `MOBSF_API_KEY` diset **dan** `consent_external_upload=true`. JADX tetap `checks_unavailable`.
- **Job retensi file (§2.4)**: `app/retention.py` menghapus objek Storage lalu baris `files`, dijalankan background task (`RETENTION_ENABLED`, `RETENTION_INTERVAL_SECONDS`) dan bisa dipicu manual lewat `POST /internal/v1/maintenance/retention`.
- **pgx direct Postgres (§2.2)**: `backend/store.go` dengan interface `dataStore` dan dua backend — `pgxStore` (mode simple protocol, kompatibel transaction pooler) dipakai bila `DATABASE_URL` diisi, `restStore` (PostgREST) sebagai fallback bila kosong/gagal. Semua handler memakai `s.db`, tidak ada lagi query REST tersebar.
- Health check analysis-service sekarang melaporkan `capabilities`: `checkpointer`, `exa`, `mobsf`, `vision`, `retention` di samping yang lama.

## Fase 4 (selesai untuk bagian yang tidak butuh kunci; diverifikasi offline)

- **Kalibrasi skor** `app/risk.py`: `risk.score` numerik 0–100 dari `severity × source × confidence`, digabung multiplikatif; cap 60 bila sumber independen < 2; `low` hanya bila ≥3 pemeriksaan positif bersih (selain itu `unknown`). `fail_report` tetap `score: null`.
- **Monitoring**: `GET /internal/v1/metrics` (service key) di analysis-service (jobs, latency, agent runs, tool calls, retries, retention) dan di go-api (scans_created/failed, jobs_completed/failed, scan_timeouts, auth_failures, `data_store`). Smoke: 200 dengan kunci, 401 tanpa.
- **Graph kondisional lanjutan**: URL graph menjalankan satu deep-check pass berbatas (`MAX_DEEP_TARGETS=2`) untuk form action lintas-domain + tujuan redirect, tanpa sesi browser kedua.
- **Dynamic APK**: `app/dynamic.py` (klien sandbox opsional, consent-gated). Tanpa `DYNAMIC_ANALYSIS_URL`, `dynamic_analysis` masuk `checks_unavailable` dan limitation menjelaskan bahwa sandbox emulator tidak tersedia — tidak ada klaim cakupan runtime palsu.
- **Exa coverage**: pesan/gambar mencatat `exa_search` di `checks_unavailable` + limitation bila Exa belum dikonfigurasi.
- **Hardening**: security headers CSP/HSTS/nosniff/Referrer-Policy/Permissions-Policy di `frontend/next.config.ts`; redaksi log `app/logs.py` (API key, JWT, hex-64, bearer, DSN); batas konkurensi job `MAX_CONCURRENT_JOBS`; `backend/.dockerignore`.
- Tes: analysis-service **148 passed**; backend `go test` lulus (termasuk tes metrics snapshot & store kind); `tsc --noEmit` + `eslint` bersih; keempat image dibangun ulang.
- Smoke di image: job pesan → `suspicious/medium/score 57`, `exa_search` muncul di unavailable, metrics counter `jobs_finished{status="completed",type="message"}`; go-api metrics `{"counters":{},"data_store":"postgrest"}`.

## Deteksi domain mirip brand (brand_guard)

- `analysis-service/app/brand_guard.py` + `app/data/brands.json` (**80 brand**: bank & e-wallet Indonesia, e-commerce/logistik, layanan global). Aturan deterministik: substitusi karakter (`g00gle.com`), typosquatting (`goggle.com`), homograph/punycode (`xn--80ak6aa92e.com`), nama brand disisipkan (`bca-login.xyz`), brand di bawah domain lain (`google.com.secure-login.xyz`), brand sebagai subdomain (medium), brand di TLD lain (medium).
- Dipasang di: URL scanner (host awal, host akhir redirect, host form action), graph pesan & gambar (setiap tautan yang diekstrak), dan domain hardcoded APK.
- Allowlist bisa diganti tanpa ubah kode: `BRAND_ALLOWLIST_PATH=/path/brands.json`; cache dibersihkan via `brand_guard.clear_cache()` (dipanggil di tes).
- Sumber temuan `brand_guard` berbobot 0.75 di risk engine → maksimal `suspicious/high`, tidak pernah `confirmed_threat` (bukan bukti positif).
- Smoke di image: `g00gle.com` → char_substitution/high, `bca-login.xyz` → brand_token/high, `xn--80ak6aa92e.com` → homograph/high, domain resmi tidak ditandai; pesan berisi tautan `g00gle.com` → `suspicious/high` (skor 55) dengan `brand_guard` di `checks_run`.
- Batasan: menandai kemiripan nama, bukan membuktikan malware; domain resmi dipakai untuk phishing dan domain acak tanpa kemiripan tidak tertangkap. Tes: `tests/test_brand_guard.py` (48 kasus). Total suite **196 passed**.

## Laporan komunitas nomor telepon (opsi A, selesai di kode)

> **Perubahan 2026-11-04:** cakupan deteksi dipersempit ke **nomor Indonesia (+62) saja**, laporan tidak lagi ditolak karena nomor belum tentu subscriber valid, dan hasil cek nomor kini menampilkan daftar review warga. Bagian di bawah ini adalah catatan per 2026-10-30; sebutan region `ID/MY/SG/US/GB` dan contoh `+65 9123 4567 → +6591234567` bukan perilaku sekarang. Lihat bagian **"Catatan 2026-11-04"**.

Pekerjaan yang sempat terhenti pada 23:54 (karena kuota) sudah dilanjutkan dan ditutup. Keputusan desain: **tidak ada integrasi GetContact / lookup nama pemilik**, karena butuh kredensial akun pihak ketiga dan menyimpan PII orang lain tanpa dasar yang jelas. Yang dibangun adalah laporan komunitas + skor kepercayaan yang bisa dijelaskan.

- **Normalisasi terpusat**: `POST /internal/v1/phone/normalize` (service key) → `{e164, valid, possible, region, line_type, carrier, parsed_by, reasons}` dari `phone_scanner.normalize_payload`. Go memakai endpoint ini sebelum menyimpan laporan, jadi hanya ada satu implementasi normalisasi. Bila analysis service tidak dapat dihubungi, Go memakai `fallbackE164` (aturan yang sama dengan `_fallback_normalize`); bila service menjawab, jawabannya final (E.164 kosong = tidak valid, tidak ditimpa fallback).
- **`POST /api/v1/phone-reports`** (authenticated): body `{number, default_region, category, note?}`. Validasi nomor/region/kategori/panjang catatan, rate limit per akun (`PHONE_REPORT_HOURLY_LIMIT`, default 10/jam, in-process), lalu insert `{number_e164, category, source: "user_report", reported_by, status: "pending"}`.
- **Dedup**: satu laporan per akun per nomor selamanya (bukan window 24 jam) karena unique index `phone_reports_reporter_number_key` dari migrasi `0004`. Balasan `409 duplicate_report`; insert yang gagal karena balapan juga dicek ulang dan dipetakan ke 409, bukan 500.
- **Moderasi**: `PATCH /internal/v1/phone-reports/{id}` (service key) di analysis-service memakai `app/phone_reports.py::set_status`, validasi UUID + status, 404 untuk id tak dikenal, 422 untuk status di luar allowlist. Hanya laporan `verified` yang menaikkan risiko.
- **Kategori tertutup** (`penipuan`, `spam`, `telemarketing`, `penagih_utang`, `peniruan_identitas`, `lainnya` — plus `phishing` dan `pharming` sejak form laporan pindah ke `/community/phone`, lihat bagian P1 di bawah) didefinisikan di `phone_reports.REPORT_CATEGORIES` (Python) dan `phoneReportCategories` (Go); label Indonesia untuk teks temuan lewat `category_label()`, nilai tak dikenal jatuh ke `lainnya`.
- **Skor kepercayaan** `phone_scanner.summarize_reports` + `_report_finding`: `high` hanya bila ≥2 laporan terverifikasi dari ≥2 pelapor berbeda; ≥1 terverifikasi → `medium`; ≥3 pending dari ≥2 pelapor → `medium`; selain itu `low`. Aturan lama "3 laporan terverifikasi saja" dihapus supaya satu akun tidak bisa mencapai `high` sendiri.
- **Catatan moderasi** (`note`, maks 280 karakter) tersimpan sebagai kolom additif baru (migrasi `0005`), tidak pernah dikirim ke LLM, tidak pernah ditampilkan ke pengguna lain. Bila kolom belum ada, laporan tetap tersimpan dan respons berisi `note_saved: false`.
- **Frontend**: `frontend/src/components/recognize/PhoneReportForm.tsx` — panel "Laporkan nomor ini" di bawah panel hasil telepon (pilih kategori, catatan opsional, status terkirim/gagal). Struktur form input tidak diubah. Pesan error baru: `duplicate_report`, `invalid_category`, `invalid_note`.
- **Metrics**: `phone_reports_created` (go-api) dan `phone_reports_moderated{status}` (analysis-service); `capabilities.phone_reports` di health analysis-service.

Migrasi yang perlu Anda terapkan di hosted SQL Editor (belum dijalankan, jangan jalankan ulang `0001`): `202610300004_phone_reports_trust.sql` lalu `202610300005_phone_reports_note.sql`. Tanpa `0004` dedup hanya dicek aplikasi; tanpa `0005` laporan tetap masuk dengan `note_saved: false`.

Verifikasi: `pytest` **214 passed** (+18 tes baru di `tests/test_phone_reports.py`, termasuk tes endpoint normalisasi & moderasi), `go test ./...` + `go vet` lulus (tes handler baru di `backend/phone_report_test.go` memakai stub `dataStore`), `tsc --noEmit` + `eslint` bersih. Rebuild image `analysis-service`, `go-api`, `frontend` sukses; smoke di container: `capabilities.phone_reports = true`, normalisasi `0812-3456-7890 → +6281234567890` dan `+65 9123 4567 → +6591234567`, region `ZZ`/nomor `123` → 422, moderasi id tak dikenal → 404 `report_not_found` (PostgREST hosted tersambung), id non-UUID → 400, status ngawur → 422, dan `POST /api/v1/phone-reports` tanpa sesi → 401.

Belum diuji: pengiriman laporan dari UI dengan sesi login sungguhan (butuh login Google manual) dan pembacaan laporan oleh scanner setelah ada baris `verified` di `phone_reports`.

## Rute `/recognize` + ikon bundel (2026-10-31)

- `/scan` dihapus dan diganti `/recognize` (`frontend/src/app/recognize/page.tsx`). Semua alur diperbarui: allowlist `safeNext` + header `x-landing-interaction` di `proxy.ts`, `app/auth/callback/route.ts`, default `next` di `app/login/page.tsx`, `LandingInteractionGuard`, link di `/history`, dan menu "Recognize" di `MenuDrawer`.
- Landing page dan `/recognize` memakai satu shell: `frontend/src/components/layout/SiteShell.tsx` (SideOrnaments + Navbar + HeroSection + ThreatsSection + WarningSection + footer). Perbedaan satu-satunya: `/recognize` mengirim `SiteShell account={...}`, sehingga navbar menampilkan foto profil Google (`user_metadata.avatar_url`/`picture`, fallback inisial) dan tombol keluar berikon. `IdleSessionMonitor` tetap aktif di `/recognize`.
- **Penyebab ikon hilang**: semua komponen memakai `@iconify/react`, yang mengambil data ikon dari `api.iconify.design` saat runtime, sedangkan CSP `connect-src` tidak mengizinkannya → ikon tampil kosong. Perbaikannya: `frontend/scripts/build-solar-icons.mjs` (`npm run icons`) memindai `src/` untuk referensi `solar:*`, memotong subset dari devDependency `@iconify-json/solar`, lalu menulis `src/components/ui/solar-icons.ts`; `src/components/ui/Icon.tsx` memakai `@iconify/react/offline` + `addCollection` + `ssr`. Semua import `Icon` kini dari `@/components/ui/Icon`.
- `next.config.ts`: `img-src` ditambah `https://*.googleusercontent.com` untuk avatar Google; `connect-src` tetap tanpa `api.iconify.design` karena tidak diperlukan lagi.
- Verifikasi: `tsc --noEmit` + `eslint` bersih, image frontend dibangun ulang dan sehat. Smoke: `/` HTTP 200 dengan 36 atribut `height="1em"` (SVG ikon benar-benar dirender, 0 placeholder `data-icon=`), `/recognize` → 307 `http://localhost:3000/login?next=%2Frecognize`, `/history` → 307 `next=%2Fhistory`, dan build `.next/server/app` hanya memuat `recognize` (tanpa `scan`).
- Catatan: `MenuDrawer` masih menautkan `Learn`, `Act`, `Panduan Keamanan` ke `/learn`, `/act`, `/guide` yang belum ada; bagi pengguna login rute itu 404. Belum diubah karena di luar permintaan.
- Belum diuji: tampilan `/recognize` saat login sungguhan (avatar Google + tombol keluar) — butuh login manual.

## Langkah berikutnya

1. **Isi `FILE_WORKER_SERVICE_KEY`**: `analysis-service/.env.worker` masih placeholder (nilai kosong), dan container `analysis-worker` bahkan belum ada di `docker ps -a`. Akibatnya `FILE_WORKER_URL=http://analysis-worker:8003` di `analysis-service` menunjuk host yang tidak resolve, jadi scan gambar/APK saat ini jatuh ke `file_worker_unavailable`. Jalankan blok PowerShell README langkah 5 dari workspace root, lalu `docker compose -f infra/docker-compose.yml up -d --build analysis-worker`; tidak ada nilai kunci yang dicetak.
2. **Terapkan migrasi `0004` lalu `0005`** di hosted SQL Editor (lihat bagian laporan komunitas di atas), lalu kirim satu laporan dari UI untuk menutup jalur tulis end-to-end.
3. Uji dari UI: scan nomor telepon (khususnya nomor `+62` yang sudah punya laporan, untuk melihat panel "Kata warga") dan APK asli, lalu pastikan hasilnya muncul di Riwayat. Ini juga menguji jalur agent (bila `OPENAI_API_KEY` valid) dan `llm_tool_calls` di `coverage.checks_run`.
4. **Verifikasi pgx**: isi `DATABASE_URL` (session/direct string) di `backend/.env`, lalu jalankan scan dan cek log `data store: pgx direct Postgres`. Tanpa itu jalur pgx belum diuji terhadap Postgres sungguhan (unit test hanya memverifikasi fallback + simple protocol). Jalur `InsertPhoneReport`/`PhoneReportExists` versi pgx juga baru teruji di level kode.
5. **Aktifkan checkpointing**: terapkan `infra/supabase/migrations/202610300002_langgraph_schema.sql` di hosted SQL Editor, set `DATABASE_URL_SESSION`, lalu pastikan `langgraph_checkpointer` hilang dari `checks_unavailable`. Jangan jalankan ulang migrasi `0001`.
6. **Aktifkan integrasi opsional** sesuai kebutuhan: `EXA_API_KEY` (verifikasi klaim) dan `MOBSF_URL` + `MOBSF_API_KEY` (APK lebih dalam, tetap butuh consent per scan). Keduanya sudah ada di kode dan muncul di `capabilities`.
7. Isi data awal `phone_reports`: tanpa laporan, phone scanner tetap `insufficient_evidence` (disengaja agar tidak menampilkan "aman" palsu). Moderasi masih manual lewat `PATCH /internal/v1/phone-reports/{id}`; belum ada UI moderator. Lanjutan yang sudah disetujui arahnya ada di bagian **P1** pada catatan 2026-11-04 (vote, bukti Cloudinary, pencarian, halaman admin).
8. Idle timeout/passive polling belum divalidasi.
9. Fase 4 tersisa: menyambungkan sandbox dinamis nyata (butuh emulator/VM terpisah) dan validasi ambang skor terhadap data nyata sebelum produksi; monitoring saat ini in-process (bukan Prometheus/Grafana), termasuk rate limit laporan per akun.

## Batasan yang diketahui

- Phone scanner memakai `phone_reports` yang masih kosong dan tidak punya sumber reputasi eksternal; `phone_reputation_service` selalu tercatat di `checks_unavailable`. Laporan komunitas sekarang bisa masuk lewat `POST /api/v1/phone-reports`, tetapi belum ada data dan belum ada UI moderator, jadi risiko nomor tetap rendah sampai ada laporan yang diverifikasi.
- Rate limit laporan (`PHONE_REPORT_HOURLY_LIMIT`) dan dedup aplikasi berjalan in-process; saat beberapa instance go-api dijalankan, hanya unique index `phone_reports_reporter_number_key` yang mencegah duplikat.
- Klasifikasi "API sensitif" APK diturunkan dari permission manifest + pemindaian string DEX mentah (URL/IP/domain, token bot Telegram, marker dynamic code loading), bukan analisis CFG penuh. Ini perlu dicatat sebagai keterbatasan, bukan bukti lengkap.
- MobSF hanya aktif bila dikonfigurasi dan pengguna menyetujui `consent_external_upload`; JADX belum ada. Dynamic APK analysis tetap Fase 4.
- OCR bergantung pada tesseract `ind` dan `eng` di image worker; bila bahasa `ind` tidak tersedia, OCR jatuh ke `eng` dan melaporkan bahasa yang benar-benar dipakai di `artifacts.ocr`.
- URL memakai Browser Intelligence, threat-intel optional, dan graph URL. Chromium worker non-root ber-resource-limit; sandbox Chromium native dinonaktifkan karena Docker Desktop host tidak mendukung unprivileged user namespace. Ini batasan hardening, perlu dievaluasi sebelum produksi.
- Network: analysis↔gateway, gateway↔worker, worker↔proxy; worker tak punya koneksi langsung ke backend atau internet. Hanya proxy yang punya egress umum dan melakukan DNS/IP pinning. `analysis-worker` hanya di network internal `worker-control` tanpa rute internet.
- LangGraph/PostgresSaver tersedia, tetapi hosted `DATABASE_URL_SESSION` kosong dan migration `0002` belum diterapkan; checkpointing belum aktif/terverifikasi di hosted DB.
- Agent LLM: satu putaran tool + satu panggilan structured output, sehingga biaya token per scan lebih tinggi daripada sebelumnya; batasnya `AGENT_TOOL_ROUNDS`/`AGENT_MAX_TOOL_CALLS`. Tanpa `OPENAI_API_KEY` agent tidak berjalan dan scanner tetap memberi hasil deterministik.
- User mengonfirmasi RLS/ownership lewat authenticated session query Supabase; server logout session juga terverifikasi. Idle/passive polling belum diuji.
- `.env` validasi dilakukan tanpa menampilkan nilainya; jangan memasukkannya ke git.
- Repo workspace sebelumnya tidak memiliki `.git`; cek status terkini sebelum menginisialisasi atau push. Jangan melakukan git init/commit/push tanpa permintaan user.
- Catatan lingkungan sesi ini: penulisan berkas dari shell ke subfolder sempat macet/tertolak (ACL Windows), sehingga `npx tsc --noEmit` diverifikasi dengan `--tsBuildInfoFile` di root dan `npm run build` lewat Docker. Perilaku aplikasi tidak terpengaruh. Perbaikan ACL permanen ada di `D:\mitweek-acl-recovery\acl-report-*.jsonl`.
- Catatan lingkungan sesi 2026-10-31: proses Python tidak bisa membuat berkas di `%TEMP%` (`PermissionError`), jadi `pytest` dijalankan dengan `$env:TEMP='D:\mitweek'` (dan `-p no:cacheprovider`). `go test`/`go vet` juga perlu `TEMP`/`TMP` itu plus `GOMODCACHE`/`GOCACHE`/`GOPATH` di root repo. `Set-Content` ke `backend\` dari shell tetap macet — ubah berkas lewat editor, bukan shell.

## Catatan 2026-11-03 — fitur gambar dan pesan dihapus

Permintaan user: proyek hanya menyisakan **deteksi URL, deteksi APK, dan deteksi nomor telepon**.

- Analysis service: `app/graph/image.py`, `app/graph/message.py`, `app/image_scanner.py`, `app/image_extract.py`, `app/image_analyze.py`, `app/qr_extract.py`, `app/file_reuse.py`, `app/vision.py`, dan `app/indicators.py` (tak lagi dipakai siapa pun) dikeluarkan dari pohon kode. `schemas.ScanType` tinggal `url | phone | application`; `capabilities()` tidak lagi melaporkan `ocr` dan `vision`; worker file hanya melayani `/internal/v1/analyze/application`.
- Go API: rute `POST /api/v1/scans/message` dan `POST /api/v1/scans/image` dihapus; `detectFileType` menjadi `detectApkType` (hanya ZIP `.apk`); `MAX_IMAGE_MB` hilang dari config dan env. Middleware `scanRateLimit` tetap dipakai: pemisahan budget teks vs berkas masih relevan untuk scan APK.
- Frontend: tab "Pesan" dan "Tangkapan Layar" hilang; `ScanTab` = `url | phone | application`; pratinjau gambar dan cabang unggahan non-APK dihapus.
- Worker deps: `pillow`, `pytesseract`, `pyzbar` dan paket apt `tesseract-ocr*` / `libzbar0` tidak dipasang lagi, sehingga image `analysis-worker` jauh lebih kecil.
- Yang sengaja DIPERTAHANKAN karena dipakai scanner lain: `heuristics.message_terms` (tool `analyze_message` untuk agen URL/APK), `file_client`/`file_worker` untuk APK, `evidence_storage`, `retention`, dan `phone_reports`.
- Migrasi `202611030001_files_sha256_index.sql` (indeks dedup gambar) tidak jadi dipakai dan belum pernah diterapkan; Supabase hosted tidak disentuh.
- Semua berkas yang dilepas (modul, test, fixture QR, migrasi, cadangan `.env`) ada di `.removed-scans/` dengan struktur path aslinya, karena workspace ini belum punya git.

## Catatan 2026-11-04 — P0 nomor telepon: +62 saja, laporan tanpa gerbang validitas, review warga di checker

Arahan user: user memposting nomor + bukti tanpa validasi, komunitas memberi upvote/downvote, gambar masuk Cloudinary, dan admin bisa menghapus review. Kesepakatan yang dikerjakan sekarang **hanya P0**: ID-only, normalisasi tidak menolak, dan daftar review tampil di checker. Tanpa migration Supabase, tanpa Cloudinary, tanpa vote.

**Cakupan +62.** `schemas.PhoneRegion = Literal["ID"]` sehingga `default_region` apa pun selain `ID` ditolak Pydantic (422). `phone_scanner.normalize_number` tidak lagi memakai region bawaan dari pemanggil untuk *mengurai* nomor — region parsing dipatok `ID`, dan yang menentukan adalah country code hasil parse (`result.domestic = parsed.country_code == 62`, reason `not_indonesia`). Alasannya: kalau region dari pemanggil dipakai, `region="SG"` membuat `+65…` terlihat normal. `REGION_CALLING_CODES` kini hanya berisi `ID`, dan `_fallback_normalize` menandai `domestic` dari prefiks `62`. `tools.ALLOWED_PHONE_REGIONS = {"ID"}`.

**Nomor asing tidak lagi diperiksa setengah-setengah.** `graph/phone.py::normalize` mengembalikan temuan `info` "berada di luar cakupan" dan mengosongkan `e164`, sehingga edge kondisional `after_normalize` melewati node `reports` — jadi tidak ada lookup `phone_reports` sama sekali untuk nomor luar, bukan "0 laporan" yang terbaca seperti vonis bersih. Tool agen `lookup_phone` mendapat gerbang yang sama (`reason: not_indonesian`) supaya satu aturan cakupan berlaku di keduanya; deskripsi argumen `number`/`default_region` ikut disesuaikan, dan setiap panggilan tetap tercatat **satu kali** di audit trail (`context.calls`).

**Laporan: normalisasi adalah kunci cari, bukan penentu sah.** `normalizePhone` (Go) sekarang mengembalikan `(e164, domestic)` dan `createPhoneReport` menolak dengan `invalid_phone` hanya bila E.164 kosong, serta `not_indonesian` bila bukan `+62`. Nomor `+62` yang `valid=false` menurut libphonenumber (misal `+628123456789012345`) **tetap tersimpan** sebagai `pending` — yang menentukan naik-tidaknya risiko adalah moderasi + jumlah pelapor berbeda, bukan aturan panjang digit. `validatePhoneReport` tetap menolak region non-ID (`allowedPhoneRegion`) sebelum panggilan ke analysis service.

**Review warga.** `phone_scanner.review_cards(rows, limit=20)` menghasilkan `{id, category, status, age_days}` untuk baris `pending`/`verified` saja (baris `rejected`/`rejected_spam` adalah hasil moderasi, bukan opini) dan mengembalikan `[]` saat sumber tidak terbaca. `graph/phone.py` menaruhnya di `report.artifacts.community_reviews` + `community_review_count`, jadi tidak perlu perubahan skema maupun Go: `GetScan` sudah mengembalikan seluruh JSONB `report`. Frontend merendernya sebagai panel **"Kata warga"** di `RecognizeCard.tsx`; `reported_by` tidak pernah keluar dari server.

**Frontend.** Pemilih region di tab telepon dihapus dan diganti chip `+62` (non-`input`), `default_region: "ID"` dikirim tetap oleh `useScanner` dan `PhoneReportForm`. Aturan digit memakai hasil terukur libphonenumber untuk ID (9–12 digit setelah `+62`) lewat `subscriberDigits` yang juga menangani `0…`, `62…`, dan `+62…`; pesan error baru `not_indonesian` = "Layanan ini hanya menerima nomor Indonesia (+62)."

**Perbaikan yang muncul dari smoke test.** `summarize_reports` menghitung `distinct_reporters` dan `last_report_days` dari **semua** baris, termasuk yang ditolak sebagai spam, sehingga kalimat temuan bisa bilang "3 pelapor berbeda · laporan terakhir 1 hari lalu" padahal hanya 2 review yang ditampilkan. Keduanya kini dihitung dari baris yang tidak ditolak (`kept`), konsisten dengan `categories` yang memang sudah mengecualikannya; `reports` tetap jumlah baris yang terbaca (volume mentah untuk moderator).

### Verifikasi

- `pytest` **222 passed**. Empat tes mengatur perilaku P0: `test_non_indonesian_numbers_are_out_of_scope` dan `test_community_reviews_are_listed_anonymously` (di `tests/test_phone_scanner.py`), plus dua yang ditambahkan saat verifikasi — `test_lookup_phone_refuses_numbers_outside_indonesia` dan `test_rejected_reports_do_not_inflate_reporters_or_recency`. Di sisi Go, `backend/phone_report_test.go` menambah `TestCreatePhoneReportRejectsNumberOutsideIndonesia` dan `TestCreatePhoneReportKeepsSixTwoNumberThatIsNotARealSubscriber`. `go build ./...` + `go test -count=1 ./...` lulus, `gofmt -l` dan `go vet` bersih. `npx tsc --noEmit` exit 0 dan `npx eslint .` exit 0.
- Image `analysis-service`, `go-api`, `frontend` dibangun ulang dan container-nya dibuat ulang; `analysis-service` healthy.
- `POST /internal/v1/phone/normalize` di container: `0812-3456-7890` → `e164=+6281234567890 valid=True domestic=True`; `+628123456789012345` → `domestic=True valid=False reasons=['invalid_for_region']` (artinya tetap boleh dilaporkan); `+12025550123` dengan `default_region=ID` → `domestic=False reasons=['not_indonesia']`; `default_region=MY` → **422** `literal_error, expected 'ID'`.
- Graph asli di container untuk `+12025550123`: `outcome=insufficient_evidence`, `level=unknown`, `checks_run=['phone_number_normalization']` (tanpa `phone_reports` → lookup benar-benar dilewati), `community_reviews=[]`, temuan "…berada di luar cakupan…".
- Graph asli untuk `0812-3456-7890`: `checks_run` berisi `phone_reports` (baca hosted berhasil) dan `community_reviews=[]` karena belum ada baris untuk nomor itu.
- Jaluran review terisi dibuktikan dengan tiga baris stub (`verified`/`pending`/`rejected_spam`) yang disuntikkan ke `fetch_reports` di dalam container: keluar 2 kartu (`age_days` 9 dan 2), temuan berbunyi "(1 laporan terverifikasi, 2 pelapor berbeda) · Laporan terakhir 2 hari lalu", dan `reported_by`/UUID pelapor tidak ada di JSON hasil. Tidak ada satu pun tulis ke Supabase (`DATABASE_URL_SESSION` kosong, dan stub hanya mengganti baca).
- `GET /api/v1/health` → 200; `POST /api/v1/phone-reports` dan `POST /api/v1/scans/phone` tanpa sesi → 401.
- Build frontend: string `Kata warga` dan "hanya menerima nomor Indonesia" ada di chunk SSR (`/app/.next/server/chunks/ssr/src_components_*.js`).

**Belum terbukti secara live:** `400 not_indonesian` dan `202` untuk nomor `+62` tak-valid di jalur HTTP Go (route-nya butuh sesi login Google nyata; JWT tidak dibuat-buat), jadi gerbang itu terbukti lewat `backend/phone_report_test.go`. Tampilan panel "Kata warga" dan chip `+62` di browser juga belum (butuh login), hanya ada di bundle hasil build.

**P1 (arah sudah disetujui, belum dikerjakan):** tabel upvote/downvote + urutan ala Reddit (vote hanya Urutan, risiko tetap dari jumlah pelapor), endpoint pencarian nomor, dan halaman admin (daftar semua nomor yang diposting + hapus review, termasuk `destroy()` bukti saat review dihapus). Butuh migration baru untuk tabel vote/audit. **Dua dari empat butir P1 sudah lebih dulu dikerjakan di P0b**: gambar bukti masuk Cloudinary (folder `threatlens/phone-reports/`, bukan `threatlens/report/` seperti rencana awal karena laporan dibuat sebelum ada baris) dan kolom bukti di `phone_reports`. Migration tidak boleh dijalankan tanpa persetujuan user, dan **P1 tidak dimulai sebelum user mengonfirmasi**.

## Catatan 2026-11-04 — P0b: halaman `/recognize/phone/[nomor]` + bukti gambar wajib

Arahan user: "1 sampai 4 sudah oke, tapi sebaiknya pindah ke page baru dengan path `/recognize/phone/[query search nomor telepon]`. di lapor komunitas juga tambahkan gambar dan ini syarat wajib. juga, di nomor telepon, kalau sudah pakai 62, gak perlu pakai 0 di depannya. setelah itu diperbaiki, konfirmasi dulu ke saya sebelum lanjut ke P1". Empat keputusan yang dikunci lewat pertanyaan: (1) hasil muncul sendiri di halaman barunya — awalnya "langsung menjalankan deteksi saat dibuka", lalu direvisi user menjadi **loading tetap di /recognize, pindah halaman setelah hasil tiba** (lihat subbagian Revisi di bawah); (2) **semua butuh login** — hasil, laporan, dan halaman barunya; (3) kalau unggah bukti gagal atau kolomnya belum ada, laporan **ditolak dengan pesan jelas** dan tidak ada yang tersimpan; (4) tab Telepon di `/recognize` tetap ada tetapi berubah jadi **kotak pencarian** — hasil deteksi tidak lagi dirender di `/recognize`.

**Kunci kanonik +62.** `0` setelah `62` dibuang di tiga bahasa (`phone_scanner._fallback_normalize` + phonenumbers, `backend/main.go::normalizePhone`, `frontend/src/lib/phone.ts`), sehingga `0812…`, `62812…`, `+62 0812…` dan `+62 0812…` jatuh ke satu kunci `+62812…`. Nomor pelanggan Indonesia tidak pernah diawali `0` sesudah +62, jadi ini bukan sekadar pemanggilatan: tanpa pembuangan itu, satu nomor punya dua baris di `phone_reports`. Aturan UI tetap 9–12 digit setelah `+62`; `phoneInputProblem()` jadi satu sumber pesan untuk form pencarian dan form laporan.

**Halaman baru.** `frontend/src/app/recognize/phone/[number]/page.tsx` await `params` **di dalam** `<Suspense>` (PPR menolak akses params di luar boundary — `next build` gagal dengan "encountered uncached or runtime data during prerendering"), redirect ke slug kanonik bila URL tidak kanonik, lalu merender `PhoneNumberResult` yang memanggil `startPhoneScan('+<slug>')` di `useEffect`. Blok hasil yang tadinya ada di `RecognizeCard` dipisah jadi `ScanResultPanel.tsx` (dipakai tab URL/APK dan halaman telepon), dengan slot `footer` tempat `PhoneReportForm` duduk. `SiteShell`/`HeroSection` dapat prop `scanner?: ReactNode` supaya rute lain bisa menyuntik hasilnya. Guard login memakai `frontend/src/lib/paths.ts::safeNext` — daftar white-list `/`, `/recognize`, `/history`, dan `/recognize/phone/[0-9]{8,20}`; sebelumnya `next=` hanya mengenal dua nilai.

**Bukti gambar wajib (transport).** `POST /api/v1/phone-reports` jadi **multipart**: `number`, `default_region`, `category`, `note?`, `evidence`. Go tidak mengirim multipart ke SDK Python, jadi berkas diteruskan sebagai base64 dalam JSON ke `POST /internal/v1/phone-reports/evidence` (service key); 5 MiB = 5.242.880 B → 6.990.508 char base64, masih di bawah batas skema 7.000.000. Urutan `createPhoneReport` penting dan sudah diuji: auth → parse multipart (`MaxBytesReader` + `ParseMultipartForm`) → validasi field → cek berkas ada → **magic byte** (`http.DetectContentType` untuk png/jpeg/webp; HEIC/HEIF lewat brand ISO-BMFF di offset 8, bukan ekstensi) → rate limit → normalisasi → cek duplikat → unggah bukti → INSERT → kalau INSERT gagal, `discard()` best-effort + 503. Tipe di luar daftar → `400 evidence_unsupported_type`; berkas hilang → `400 evidence_required`; terlalu besar → `413 evidence_too_large`; penyimpanan mati → `503 evidence_unavailable` dan **tidak ada baris DB**. Bukti tidak boleh hilang saat retry: `note` boleh dilepas, `evidence_url`/`evidence_public_id` tidak. `pgxStore.InsertPhoneReport` sekarang menyusun kolom dinamis supaya masih jalan di database yang belum bermigrasi.

**Privasi.** Aset masuk `threatlens/phone-reports/<user_id>/<report_id>-<8 byte acak>`; suffix acak (`secrets.token_urlsafe(8)`) membuat URL tidak bisa dijelajahi. `discard()` menolak public_id di luar folder itu — screenshot scanner (`threatlens/scans`) tidak bisa dijangkau dari endpoint laporan. `reported_by` tetap tidak pernah keluar dari server; yang tampil hanya URL gambar.

### Dua bug Cloudinary yang ditemukan lewat smoke test live

SDK `Config._load_config_from_env` memakai kunci `CLOUDINARY_*` **kalau `CLOUDINARY_CLOUD_NAME` ada**, dan hanya mengurai `CLOUDINARY_URL` kalau nama cloud itu **tidak ada**. Deployment ini mengatur keduanya, jadi `cloudinary.config(cloudinary_url=..., cloud_name=...)` menghasilkan objek config tanpa `api_key`/`api_secret` dan upload gagal — di `app/phone_evidence.py` dan di `app/browser_client.py` (tangkapan layar scanner). Keduanya sekarang mengurai URL sendiri: key+secret dari URL, `cloud_name` = `CLOUDINARY_CLOUD_NAME` dengan fallback ke host URL — persis presedensi yang dipakai SDK. Nama cloud yang benar `wbthmsn0`; host di `CLOUDINARY_URL` (`dlwbthmsn0`) **tidak valid** dan menolak dengan `AuthorizationRequired Invalid cloud_name` — dibuktikan dengan mengunggah ke kedua nama. `browser_client.py` sebelumnya menelan kegagalan ini senyap (`screenshot_path = None`), jadi "scanner tidak punya screenshot" tidak pernah terdengar.

Temuan kedua: setelah `destroy()` berhasil, URL lama tetap dilayani **200** dari CDN. `discard()` kini memanggil `cloudinary.uploader.destroy(public_id, resource_type="image", invalidate=True)`; dengan invalidasi, gambar yang sudah dihapus mengembalikan `404` dalam ≤30 detik (diuji live dengan polling 0/30/90/150 s).

### Migration 0006 — sudah diterapkan user

`infra/supabase/migrations/202611040006_phone_reports_evidence.sql` dijalankan sendiri oleh user di Supabase SQL Editor pada 2026-11-04, dan terbaca dari aplikasi: `GET /rest/v1/phone_reports?select=id,evidence_url,evidence_public_id&limit=1` → **200** (kalau kolomnya belum ada, PostgREST membalas 400 "column does not exist"). Isinya: `evidence_url` + `evidence_public_id` (nullable), tiga constraint bentuk (`^https://res\.cloudinary\.com/`, `LIKE 'threatlens/phone-reports/%'`, pasangan keduanya null/bukan-null bersamaan), dan komentar kolom. Kodenya aman sebelum dan sesudah migration: tanpa kolom, Go mengembalikan `503 service_unavailable` dan menghapus gambar yang terlanjur naik — tidak ada laporan tanpa bukti.

### Verifikasi

- `pytest` **246 passed** (14 di antaranya `tests/test_phone_evidence.py`), `go build ./...` + `go test ./...` lulus, `gofmt -l`/`go vet` bersih, `npx tsc --noEmit` dan `npx eslint .` exit 0, `next build` sukses dan `/recognize/phone/[number]` tercatat sebagai route **Partial Prerender** di `app-path-routes-manifest.json` + `prerender-manifest.json`.
- Round-trip Cloudinary asli dari container `analysis-service`: health `phone_evidence: True` → `POST /internal/v1/phone-reports/evidence` **201** dengan `res.cloudinary.com` dan public_id di dalam `threatlens/phone-reports/` (png 69 byte) → URL menyajikan **200 image/png** → `DELETE` **200 `{"deleted": true}`** → setelah invalidasi **404** (t+0 s masih 200, t+30 s 404 dan tetap 404 sampai t+150 s).
- `mime` di luar daftar ditolak: `image/gif` → `503 evidence_unavailable` (Go sudah menolaknya lebih awal dengan `400 evidence_unsupported_type`).
- Rute Go multipart tanpa sesi → **401 `unauthenticated`** (auth terjadi sebelum parsing, jadi tamu tidak bisa memaksa upload).
- Frontend: `/login` **200**; `/recognize`, `/recognize/phone/628123456789`, dan `/recognize/phone/08123456789` → **307** ke `/login?next=…` (nilai `next` dipertahankan dan dilewatkan ke white-list `safeNext`).
- Image `analysis-service`, `go-api`, `frontend` dibangun ulang dan container dibuat ulang dari source terkini; semuanya healthy/running.

**Belum terbukti secara live:** (1) POST laporan dengan gambar yang sebenarnya — butuh sesi login Google nyata (JWT tidak dibuat-buat); kolom `evidence_*` sudah ada sejak user menjalankan `0006`, jadi ini tinggal satu langkah uji di browser. (2) tampilan halaman `/recognize/phone/…` di browser (butuh login) — keberadaannya hanya terbukti dari manifest build + redirect 307; (3) jalur unggah screenshot scanner: browser worker mengembalikan `error: navigation_failed` untuk `example.com`, `neverssl.com`, dan `wikipedia.org` di lingkungan Docker ini (host punya internet, `browser-egress` bisa DNS, log egress kosong), jadi perbaikan `browser_client.py` baru terbukti di level kode, bukan live. Itu kondisi terpisah dari pekerjaan hari ini dan perlu dicek sendiri.

### Revisi alur (2026-11-04): loading tetap di `/recognize`

Klarifikasi user: *"maksud saya tuh pas animasi loading proses search itu masih di /recognize baru setelah dapat hasilnya akan pindah ke page baru"*. Jadi keputusan (1) dibalik yang mengerjakannya: bukan halaman hasil yang memindai, tapi kotak pencarian di `/recognize`.

- `RecognizeCard.tsx`: `searchNumber` memvalidasi (`phoneInputProblem`) → `scan.startPhoneScan(scan.number)` → spinner `scan.scanStep` dirender **di dalam tab telepon**, input dan tombol **Cari** `disabled` selama berjalan (`searchNumber` juga menolak saat `scan.isScanning`). Navigasi dilakukan dari `useEffect` yang menunggu `scan.result`; kalau yang tiba adalah `scan.errorMessage`, effect membatalkan dan pesan tampil di tempat — nomor yang gagal tidak diterbangkan ke halaman hasil.
- Penanda "sedang menunggu hasil" memakai `useRef`, bukan `useState`: `eslint-config-next` menolak `setState` di dalam effect (`react-hooks/set-state-in-effect`), dan flag ini memang tidak ada di UI.
- `frontend/src/lib/phoneHandoff.ts`: Map module-level `slug → ScanResult`, dibatasi 20 entri (FIFO). **Membaca tidak menghapus** — React menjalankan effect dua kali di development, dan read yang mengonsumsi akan membuat pass kedua melihat "tidak ada apa-apa" lalu men-scan ulang nomor yang barusan diperiksa.
- `PhoneNumberResult.tsx`: `shown = scan.result ?? arrived`, dan `useEffect` hanya memanggil `startPhoneScan` bila cache untuk slug itu kosong. Karena itu pencarian dari `/recognize` langsung menampilkan verdict tanpa spinner kedua, sementara bookmark, tautan orang lain, dan refresh tetap diperiksa dari awal. Saat mencari nomor lain dari halaman hasil, `hiddenSlug` menyembunyikan verdict lama dan `!scan.isScanning` menjaga panel tidak menampilkan hasil nomor sebelumnya selama transisi.
- Verifikasi: `npx tsc --noEmit` dan `npx eslint .` bersih, `next build` sukses dengan `/recognize/phone/[number]` tetap **Partial Prerender**, image `frontend` dibangun ulang; string "Memeriksa nomor…" dan modul handoff ada di chunk SSR yang terdeploy, `/login` **200**, dan `/recognize/phone/628123456789` tetap **307** ke `/login?next=…`.
- **Belum dibuktikan di browser:** urutan klik sebenarnya (login → tab Telepon → loading → URL berubah → hasil muncul tanpa scan kedua). Butuh sesi login Google Anda; saya tidak membuat JWT.

**P1 tetap menunggu.** Upvote/downvote, endpoint pencarian nomor, dan halaman admin belum disentuh, dan tidak akan dimulai sampai user mengonfirmasi.

## Catatan 2026-11-04 — `/community`: board cerita warga (P1 sebagian)

Arahan user: "tambahkan /community, di page ini, akan ada seperti sosial media (seperti reddit) bisa untuk post nomor telepon, bisa post pengalamannya dan ada pilihan kategorinya sebelum post pengalaman… ada upvote dan downvote. bisa komen dan reply komen. jadi ada 3 tab… buatkan juga UInya". Enam keputusan yang dikunci lewat pertanyaan: (1) **lima kategori saja** — `phishing`, `penipuan`, `pharming`, `spam`, `peniruan_identitas` (telemarketing dan penagihan masuk `spam`); (2) **tabel `community_posts` terpisah** dari `phone_reports` — cerita warga **bukan** sinyal risiko; (3) **bukti gambar tetap wajib**; (4) **alias otomatis per akun** `Warga-<6 hex>`, `author_user_id` tidak pernah keluar dari server; (5) semua route butuh login; (6) migrasi dijalankan user sendiri, bukan saya.

**Anti-fitnah adalah aturan utamanya.** Vote hanya mengubah **urutan** feed. "Nomor berbahaya" dibaca dari view `dangerous_numbers` yang ambangnya persis aturan `high` di `app/phone_scanner.py::summarize_reports` (≥2 laporan terverifikasi dari ≥2 pelapor berbeda) dan tetap bersumber dari `phone_reports`. Cerita yang paling ramai tidak bisa membuat sebuah nomor tampak berbahaya — itu alasan tab-nya dipisah, bukan digabung jadi satu daftar.

**Skema** (`infra/supabase/migrations/202611040007_community_posts.sql`, **belum dijalankan**): `community_posts` (kunci `+62` dengan bentuk sama seperti laporan, `category` check 5 nilai, judul 4–120, isi 10–4000, `evidence_url` + `evidence_public_id` dengan constraint yang sama, `author_alias` `^Warga-[0-9a-f]{6}$`, counter + `score integer generated always as (up_count - down_count) stored`), `community_votes` (PK `(post_id, user_id)`, value ±1), `community_comments` (self-FK `parent_id` + pemicu `community_comments_depth` untuk satu tingkat), RPC `cast_vote(p_post_id, p_user_id, p_value)` `security definer` (satu statement → aman dari race dan tetap jalan lewat PostgREST tanpa DSN), view `dangerous_numbers`, dan index `(score desc, created_at desc) where status='active'`. Tiga jebakan yang ditemukan dan dihindari: PostgREST hanya menerima **nama kolom** di `order=`, makanya `score` jadi kolom generated yang disimpan; `force row level security` pada view membuatnya kosong senyap, karena view berjalan sebagai **owner**-nya (`postgres`) — RLS biasa + revoke grant untuk `anon`/`authenticated` yang dipakai, `service_role` sudah `bypassrls`; dan **CHECK tidak boleh berisi subquery** di PostgreSQL, jadi aturan "tidak ada balasan dari balasan" pindah ke pemicu `BEFORE` (versi awalnya `not exists (…)` dan gagal dengan `cannot use subquery in check constraint` pada baris ke-73).

**API Go** (`backend/community.go`, 6 route di bawah `s.authenticated`): `POST/GET /api/v1/community/posts`, `GET /api/v1/community/posts/{postID}`, `POST …/{postID}/vote`, `POST …/{postID}/comments`, `GET /api/v1/community/dangerous-numbers`. Urutan `createCommunityPost` sengaja sama dengan laporan: parse multipart → validasi field → cek berkas → magic byte → rate limit (`COMMUNITY_POST_HOURLY_LIMIT=6/jam`) → normalisasi +62 → unggah bukti → INSERT; kalau INSERT gagal, bukti `discard()` dan `503`. Alias = HMAC-SHA256 atas `PRE_COOKIE_SECRET` (`s.sign`) → stabil per akun, tapi ganti secret berarti ganti semua alias. Balasan ke balasan ditolak `400 reply_too_deep` (pemicu `community_comments_depth` menegakkan hal yang sama di database), dan parent harus hidup di post yang sama.

**UI** (`frontend/src/{lib/community.ts,hooks/useCommunity.ts,components/community/*}`, plus `app/community/page.tsx` dan `app/community/[id]/page.tsx`): tab **Terbaru / Terpopuler / Nomor berbahaya**, kartu post (kategori, alias, waktu relatif, kutipan, thumbnail bukti, nomor → `/recognize/phone/[slug]`, ▲▼, jumlah komentar), panel tulis (kategori dipilih dulu — tidak ada nilai default; +62; judul; isi; bukti wajib dengan pratinjau lokal), halaman detail dengan komentar dua tingkat, dan `?nomor=` sebagai satu-satunya cara memfilter board ke satu nomor (baris "Nomor berbahaya" menautkan ke sana). `paths.ts::safeNext` sekarang mengenal `/community` dan `/community/<uuid>`.

**Bukti gambar cerita memakai jalur yang sudah ada**: `storePhoneEvidence`/`discardPhoneEvidence` dan folder `threatlens/phone-reports/<user_id>/…`; tidak ada folder Cloudinary baru, dan `discard()` menolak public_id di luar folder itu.

### Verifikasi

- `gofmt -l` kosong, `go vet ./...` bersih, `go test ./...` → `ok threatlens/backend` (17 tes baru di `backend/community_test.go`: alias + penyimpanan bukti, stabilitas alias, penolakan payload, bukti wajib, penolakan non-+62, bentuk mustahil, 503 saat bukti ditolak, bukti dihapus saat INSERT gagal, rate limit per jam, kanonisasi `communityNumberKey`, filter list + `my_vote`, kategori tak dikenal, vote/withdraw/tak-valid, vote di post terhapus → 404, `commentThread` (nesting + yatim), alias komentar, reply terlalu dalam, parent dari post lain, komentar kepanjangan, detail + untaian, id cacat → 404, baris berbahaya + fail-closed 503, dan `TestCommunityRoutesRequireLogin`). Tidak ada tes yang mengizinkan `author_user_id` keluar: `communityPostColumns` memang tidak menyertakannya.
- `npm run icons` → 35 ikon (semua nama baru dicek ada di `@iconify-json/solar` sebelum dipakai), `npx tsc --noEmit` exit 0, `npx eslint .` exit 0, `next build` sukses dengan `/community` dan `/community/[id]` tercatat sebagai **Partial Prerender**.
- Aturan `react-hooks/set-state-in-effect` menjegal efek "muat saat mount" dua kali (`useCommunity` dan `PostThread`); polanya sama dengan poll di `useScanner`: kickoff dibungkus `setTimeout(..., 0)` dengan `clearTimeout` di cleanup, sehingga spinner tidak di-set sinkron di body effect.

### Migration 0007 sudah diuji di Postgres sekali-pakai

Supaya "belum dijalankan user" tidak berarti "belum pernah dijalankan sama sekali", `0007` dieksekusi di container sementara dari image yang sudah ada di mesin ini (`public.ecr.aws/supabase/postgres:17.11.0.004`, punya role `anon`/`authenticated`/`service_role`), dengan tabel `phone_reports` minimal sebagai permukaannya. Container dan berkas ujinya sudah dihapus; pengecekan ini tidak menyentuh hosted database sama sekali. Hasilnya:

1. `0007` jalan bersih setelah dua perbaikan (sebelumnya gagal di baris 73: `cannot use subquery in check constraint`).
2. INSERT post dengan kolom persis seperti `pgxStore.InsertCommunityPost` → `INSERT 0 1`; `select` dengan `communityPostColumns` dan `communityCommentColumns` milik `restStore` → semua nama kolom ada.
3. `cast_vote`: up → `1/0`, akun lain down → `1/1`, akun pertama pindah ke down → `0/2`, cabut → `0/1`, `score` = `-1`. Cocok dengan `withLocalVote()` di frontend (pindah suara menggeser satu dari masing-masing kolom).
4. Vote pada post `removed` → `post_not_found`; balasan dari balasan → `reply_too_deep` dari pemicu; kategori liar / nomor `+1` / bukti di luar `threatlens/phone-reports/` → `check_violation`; `update … set score = 99` → `column "score" can only be updated to DEFAULT`.
5. `comment_count` = 2 dari trigger setelah dua komentar; view `dangerous_numbers` mengembalikan **satu** baris (`+6281234567890`, 2 terverifikasi dari 2 pelapor, `community_posts=1`, `community_score=-1`) dan **tidak** menampilkan nomor dengan satu laporan terverifikasi — ambang terbukti, bukan cuma ditulis.
6. `delete from community_posts` → komentar ikut terhapus (`sisa_komentar = 0`) **tanpa error**, yang adalah bukti perbaikan trigger `community_comments_sync_count_delete`; versi lamanya membaca `new.post_id` di trigger DELETE dan akan gagal justru di jalur cascade ini.
7. `set role anon` → ditolak membaca view dan menulis post; `authenticated` → ditolak membaca `community_votes`; `service_role` → `select` view berhasil (1 baris).

Cek terakhir sempat memberi `permission denied for schema public` untuk `service_role` — itu kelakuan image sekali-pakai tersebut (role-nya tidak diberi `usage` pada schema `public`), bukan isi migration; setelah `grant usage on schema public to service_role` di test harness, cek itu lolos.

**Sudah terbukti lewat HTTP tanpa login:** `/community` → **307** `http://localhost:3000/login?next=%2Fcommunity`, `/community/<uuid>` → **307** dengan `next` dipertahankan, `/community/not-a-uuid` → **307** `next=%2Frecognize` (bukan white-list `safeNext`), dan `GET/POST /api/v1/community/...` tanpa sesi → **401 `unauthenticated`** (auth terjadi sebelum apa pun). Image `go-api` + `frontend` dibangun ulang dan container dibuat ulang; string board, panel tulis, tab, komentar, dan ikon baru (`alt-arrow-up-bold-duotone`, `shield-warning-bold-duotone`) ditemukan di chunk `.next` yang terdeploy.

**Sudah terbukti:** migrasi `0007` sudah dijalankan user di hosted SQL Editor (2026-11-04), jadi keenam route komunitas itu sudah punya tabel untuk dibaca; sebelum itu list dan "Nomor berbahaya" membalas `503 service_unavailable` dan post membalas `503` setelah gambarnya sudah naik (fail-closed: tidak ada baris tanpa bukti, dan bukti dibuang kalau barisnya gagal).

**Belum terbukti:** belum ada satu pun permintaan komunitas **dengan sesi login nyata** (butuh akun Google Anda; JWT tidak dibuat-buat), jadi render board, hasil vote, unggah bukti, dan untaian komentar belum dilihat di browser.

### UI papan cerita dibangun ulang: bahasa visual feed foto (Instagram), bukan "papan reddit"

Arahan pertama: "buatkan UI /community yang rapi seperti sosmed reddit… jangan pakai UI yang sama dengan yang ada di landing page". Versi yang lahir dari arahan itu (cangkang tinta, Archivo + Newsreader, pelat caller-ID, rel vote vertikal, palet "Pos Ronda") sudah dikerjakan dan terverifikasi, lalu **ditolak user**: "TERLALU AI SLOP. BUAT UI DESIGNNYA SEPERTI INSTAGRAM SAJA." Yang dihapus karena penolakan itu: blok `@theme` "Pos Ronda" beserta sebelas tokennya, `lib/fonts.ts` (Archivo + Newsreader, dan impor variabelnya di `layout.tsx`), `NumberPlate`, dan rel vote vertikal. Yang tetap: `SiteShell` tidak dipakai papan, dan landing page/`/recognize` tidak tersentuh satu token pun (dibuktikan dengan grep sebelum menghapus — nol pemakaian di luar `components/community`).

Yang sekarang ada di papan, semuanya pinjam dari tata bahasa feed foto, bukan dari template SaaS:

- **Kanvas `#fafafa`, permukaan putih, hairline `#dbdbdb`, tanpa bayangan di feed.** Token `--color-pos-*` di `app/globals.css`: `shell`, `card`, `line`, `ink`, `muted`, `action` (#0095f6), `action-tua`, `flag`, `good`, `bad`. Biru itu hanya untuk **isian** (tombol, link teks); teks biru di atas putih memakai `action-tua` karena #0095f6 di atas putih cuma ~3:1.
- **Huruf sistem** (`--font-pos-ui`: `-apple-system, "Segoe UI", Roboto, …`). Tidak ada webfont yang di-fetch papan lagi, jadi tidak ada `next/font/google` di jalur ini dan `font-src 'self'` tidak pernah diuji.
- **Angka sebagai handle.** `NumberHandle` menaruh `+62 812-3456-7890` tebal di baris pertama dan menautnya ke `/recognize/phone/[slug]`; penulis turun jadi `Warga-9f2c1a · 28 Okt` di bawahnya. Alasannya produk, bukan gaya: satu-satunya fakta yang disepakati semua saksi adalah nomor mana yang menelepon.
- **Cincin gradien = terverifikasi.** `NumberAvatar` memakai gradien 45° merah→oranye khas story-ring, dan hanya dipakai di daftar "Nomor berbahaya" untuk satu klaim: nomor itu lewat ambang laporan terverifikasi. Yang belum terverifikasi dapat cincin abu.
- **Ikon outline → filled** untuk tab dan vote (bukan ganti warna), target 44px bulat, skor vote hanya lewat `sr-only` `aria-live`; angka vote tidak pernah tampil sebagai "skor" di layar. Baris hitungan model "disukai oleh": "24 menganggap berguna · 2 menganggap tidak".
- **Ukuran feed 470px** dan tidak melebar di layar lebar; tiga kolom (rail 244 / feed 470 / catatan 340) di `xl`, rail pindah jadi bar bawah empat item di bawah `lg`; halaman cerita dua pane (media panggung gelap / komentar digulir dengan kotak komentar menempel di bawah) mulai `lg`; panel tulis jadi **modal dua langkah** (seret bukti → tulis) dengan `role="dialog"`, Escape, dan kunci scroll.
- Kategori tidak lagi pil berwarna: `CategoryChip` jadi label berhairline tanpa warna, supaya "phishing" tidak terlihat seperti vonis risiko.

Semua jalur data dibiarkan apa adanya — bentuk fetch, `withLocalVote`, bukti wajib, tanpa kategori default, balasan satu tingkat, kanonisasi `?nomor=`, `router.replace` saat pindah tab. Yang berubah hanya presentasinya.

Verifikasi: `npm run icons` → 38 ikon (nama baru dicek ada di `@iconify-json/solar`; kalau tidak, skripnya melempar error, jadi ini juga gerbang), `npx tsc --noEmit` exit 0, `npx eslint .` exit 0, `next build` sukses dengan `/community` dan `/community/[id]` tetap Partial Prerender, image `frontend` dibangun ulang + container dibuat ulang, lalu HTTP: `/` → 200, `/community` → **307** `next=%2Fcommunity`, `/community/<uuid>` → **307** dengan `next` utuh, `/recognize` → 307, `/login` → 200.

Cara memfotonya, dan dua jebakan yang terbukti di jalan:

1. Halaman scratch `/preview`, `/preview/board`, `/preview/thread` memasang `window.fetch` untuk `/api/v1/community/*` dengan data contoh (`app/preview/fixtures.ts`) sehingga **komponen papan yang sungguhan** ter-render tanpa sesi login; `?klik=Nomor|Cerita` menekan tombol tab/panel lewat DOM seperti yang dilakukan pengguna. Setelah foto selesai, seluruh `src/app/preview/**` dihapus dan `src/proxy.ts` dikembalikan ke white-list tiga path — lalu dibuktikan: `/preview/board` sekarang 307 ke login, dan `next build` tidak lagi memuat rute itu.
2. **Viewport lingkungan ini menipu.** Browser in-app mentok 524px, dan `--window-size=390` di headless Chrome diam-diam memakai viewport ~500px lalu memotong PNG-nya ke 390 — hasilnya tampak seperti konten yang meluber padahal tidak. Foto desktop sekarang diambil dengan headless Chrome `--window-size=1280,900 --virtual-time-budget=20000` (budget waktu virtual itu yang membuat hydration + fetch `setTimeout(0)` selesai sebelum capture), dan foto ponsel 390px CSS yang asli lewat CDP `Emulation.setDeviceMetricsOverride` (skrip sekali-pakai `cdp-shot.cjs` di folder foto sementara, bukan di repo). Truk iframe tidak bisa: CSP papan berbunyi `frame-ancestors 'none'`, jadi isinya hanya ikon gambar rusak.
3. **Jebakan PPR pada waktu relatif** tetap berlaku: `timeAgo()` memanggil `Date.now()` di dalam Client Component, dan itu membalas `unstable value Date.now() in a Client Component` begitu komponen ikut ter-prerender dengan data. Board/halaman cerita sungguhan aman karena daftar baru dirender setelah fetch di browser.

Yang masih **belum** terbukti: satu pun permintaan komunitas dengan sesi login nyata (butuh akun Google Anda; JWT tidak dibuat-buat) — jadi hasil vote ke server, unggah bukti asli, dan untaian komentar masih menunggu uji browser oleh Anda (task #32).

### Tiap tab dapat alamat sendiri; tombol lapor nomor dipisah dari tombol cerita

Arahan user: "tiap page buat pathnya sendiri… /community/latest, /community/popular, /community/phone. tombol cerita baru berada di tab terbaru dan terpopuler sedangkan tombol post nomor berbahaya itu di tab nomor berbahaya".

- `app/community/page.tsx` sekarang hanya meneruskan ke `/community/latest` (membawa `?nomor=`), jadi alamat lama yang sudah tersebar di bookmark, menu landing, dan tautan hasil pindai tidak mati. Rutenya berlabel `ƒ Dynamic` dengan `export const instant = false`: target redirect dibangun dari query, jadi tidak ada yang bisa di-prerender. Tiga rute tab (`latest`, `popular`, `phone`) tetap Partial Prerender.
- `tab` tidak lagi `useState` di dalam board; ia datang dari rute lewat `BoardPage` (`components/community/BoardPage.tsx`) yang merangkum auth + cangkang + Suspense, sementara tiap `page.tsx` cuma tiga baris. Konsekuensi yang diinginkan: tab bisa di-share, di-reload, dan dituju tombol back.
- Item rail dan bar bawah jadi `<Link>` dengan `aria-current="page"`, bukan `<button>` + `router.replace`. `?nomor=` ikut berpindah antar latest↔popular dan **dilepas** saat masuk `/community/phone` karena daftar itu tidak disempitkan oleh satu nomor.
- Slot keempat (rail dan bar bawah) kini mengikuti tab: "Cerita baru" (membuka modal composer) di latest/popular, dan "Lapor nomor berbahaya" (membuka form laporan) di phone. `/community/phone` sengaja tidak punya tombol cerita sama sekali.
- Koreksi arahan setelah itu (user: *"tombol lapor no teleponnya itu bukan mengarah ke /recognize tapi emang buat laporan nomor berbahayanya di page /community/phone"*): slot phone bukan lagi tautan keluar, tapi tombol yang membuka `components/community/ReportNumberPanel.tsx` — form laporan yang benar-benar berdiri sendiri di halaman itu.
- `lib/paths.ts` mengenal `/community/latest|popular|phone` supaya login round-trip kembali ke tab yang sama. Catatan: proxy hanya mengirim `pathname` ke `safeNext`, jadi `?nomor=` tetap hilang lewat login (perilaku lama, belum diubah).

Verifikasi rute baru: `npm run icons` → 39 (ikon `solar:phone-calling-bold-duotone` ditambahkan; `phone-add-bold-duotone` tidak ada di koleksi Solar dan gate-nya memang melempar error), `tsc` exit 0, `eslint` exit 0, `next build` sukses dengan tiga tab ◐ PPR + `/community` ƒ, image + container dibangun ulang, lalu HTTP tanpa sesi: `/` → 200, `/community` → 307 `next=%2Fcommunity`, `/community/latest|popular|phone` → 307 dengan `next` masing-masing, `/community/not-a-uuid` → 307 `next=%2Frecognize`. Struktur tautan dicek di DOM (render dengan data contoh): tab membawa `?nomor=` antar tab cerita, lepas di tab phone, tautan "Cerita" di daftar now `/community/latest?nomor=…`, dan tidak ada tombol cerita di `/community/phone`.

### Form laporan nomor tinggal di `/community/phone` (2026-11-04)

- `ReportNumberPanel` dipasang bersyarat dari `CommunityBoard` (`{reporting && <ReportNumberPanel … />}`), bukan dipertahankan ter-mount seperti `CreatePostPanel`. Alasannya: draft cerita panjang memang sayang kalau hilang, sedangkan form laporan yang sudah sukses tidak boleh bisa dikirim dua kali hanya karena tombolnya dibuka lagi — tiap buka mulai dari kosong.
- Isinya empat bidang, sama seperti kontrak endpoint: nomor (`+62` di luar input, preview bentuk kanonik), kategori (lima chip papan, tanpa nilai awal), bukti gambar (wajib, drag-drop atau galeri, pratinjau + hapus, batas 5 MB dicek dari sisi klien supaya tidak uploads yang pasti ditolak), catatan moderator ≤ 280. Kirim → `POST /api/v1/phone-reports` multipart dengan `default_region: ID`; status lanjutannya tetap `pending`, dan layar setelah kirim menyebut ambang "2 laporan terverifikasi dari 2 warga berbeda" — bukan "terima kasih, nomor ini sekarang berbahaya".
- Konsekuensi yang harus ikut berubah: `phoneReportCategories` di Go dan `REPORT_CATEGORIES` di analysis-service sebelumnya hanya mengenal `penipuan`, `spam`, `telemarketing`, `penagih_utang`, `peniruan_identitas`, `lainnya`. Form papan menawarkan lima kategori papan, jadi `phishing` dan `pharming` ditambahkan ke kedua daftar itu (menambah, tidak mengganti — `/recognize` tetap menawarkan enamnya). Tidak ada migrasi: kolom `phone_reports.category` tidak punya `check`, dan `category_label()` memang jatuh ke `lainnya` untuk nilai tak dikenal, jadi tanpa tambahan ini laporan phishing yang diverifikasi akan tertulis "lainnya" di hasil pindai.
- Verifikasi: `go test ./...` lulus (dengan kasus baru di `TestValidatePhoneReportRejectsBadInput` yang menerima keempat kategori papan), `pytest tests/test_phone_reports.py` 19 lulus, `npm run icons` → tetap 39 ikon (tidak ada nama baru), `tsc` exit 0, `eslint` exit 0, `next build` sukses tanpa rute scratch, image `go-api` + `analysis-service` + `frontend` dibangun ulang dan container dibuat ulang (semua `running`, analysis-service `Healthy`). HTTP: `/` → 200, `/community/phone` → 307 `next=%2Fcommunity%2Fphone`, dan string "Lapor nomor berbahaya" ada di chunk client + SSR hasil build.
- Tangkapan layar form (rute scratch sementara, sudah dihapus lagi bersama pengecualian proxy-nya): `report-1280.png`, `rail-report-1280.png`, `m390-report.png` di `AppData/Local/Temp/shots` — 390 px-nya lewat CDP `Emulation.setDeviceMetricsOverride`, jadi benar-benar 390 CSS px, bukan crop.
- Yang **belum** terbukti: pengiriman laporan sungguhan dari form ini (butuh login + upload gambar nyata; tidak ada JWT buatan dan tidak ada baris yang ditulis ke database hosted dari sisi saya). Uji browser tetap task #32/#26.



