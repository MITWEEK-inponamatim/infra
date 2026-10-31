# ThreatLens Progress Handoff

Dokumen ini melengkapi spesifikasi utama di `threatlens-handoff.md`. Baca keduanya sebelum lanjut.
Terakhir diperbarui: 2026-10-31 setelah laporan komunitas nomor telepon (opsi A) selesai di kode dan terverifikasi di Docker.

## Workspace empat repo (2026-10-31)

- `D:\mitweek` adalah workspace lokal, bukan repo Git. `infra/` berisi Compose, Supabase, README, dan handoff docs; `frontend/`, `backend/`, `analysis-service/` adalah folder layanan sejajar.
- Jalankan Compose dari workspace root: `docker compose -f infra/docker-compose.yml ...`. Compose project name dipatok `mitweek` agar cocok dengan container stack yang sudah ada.
- Supabase config/migrations dan env lokal berada di `infra/supabase/`. File `.env` dipindah tanpa dicetak; `.gitignore` infra mengecualikannya.
- Setiap repo layanan punya `.gitignore` sendiri; belum ada `git init`, commit, remote, atau push. User akan melakukan commit/push manual.

## Status sekarang

- Fase 1 tersedia dan user mengonfirmasi scan pesan, scan URL, Riwayat, ownership isolation, serta server logout.
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

Pekerjaan yang sempat terhenti pada 23:54 (karena kuota) sudah dilanjutkan dan ditutup. Keputusan desain: **tidak ada integrasi GetContact / lookup nama pemilik**, karena butuh kredensial akun pihak ketiga dan menyimpan PII orang lain tanpa dasar yang jelas. Yang dibangun adalah laporan komunitas + skor kepercayaan yang bisa dijelaskan.

- **Normalisasi terpusat**: `POST /internal/v1/phone/normalize` (service key) → `{e164, valid, possible, region, line_type, carrier, parsed_by, reasons}` dari `phone_scanner.normalize_payload`. Go memakai endpoint ini sebelum menyimpan laporan, jadi hanya ada satu implementasi normalisasi. Bila analysis service tidak dapat dihubungi, Go memakai `fallbackE164` (aturan yang sama dengan `_fallback_normalize`); bila service menjawab, jawabannya final (E.164 kosong = tidak valid, tidak ditimpa fallback).
- **`POST /api/v1/phone-reports`** (authenticated): body `{number, default_region, category, note?}`. Validasi nomor/region/kategori/panjang catatan, rate limit per akun (`PHONE_REPORT_HOURLY_LIMIT`, default 10/jam, in-process), lalu insert `{number_e164, category, source: "user_report", reported_by, status: "pending"}`.
- **Dedup**: satu laporan per akun per nomor selamanya (bukan window 24 jam) karena unique index `phone_reports_reporter_number_key` dari migrasi `0004`. Balasan `409 duplicate_report`; insert yang gagal karena balapan juga dicek ulang dan dipetakan ke 409, bukan 500.
- **Moderasi**: `PATCH /internal/v1/phone-reports/{id}` (service key) di analysis-service memakai `app/phone_reports.py::set_status`, validasi UUID + status, 404 untuk id tak dikenal, 422 untuk status di luar allowlist. Hanya laporan `verified` yang menaikkan risiko.
- **Kategori tertutup** (`penipuan`, `spam`, `telemarketing`, `penagih_utang`, `peniruan_identitas`, `lainnya`) didefinisikan di `phone_reports.REPORT_CATEGORIES` (Python) dan `phoneReportCategories` (Go); label Indonesia untuk teks temuan lewat `category_label()`, nilai tak dikenal jatuh ke `lainnya`.
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
3. Uji dari UI: scan nomor telepon, tangkapan layar (OCR), dan APK asli, lalu pastikan hasilnya muncul di Riwayat. Ini juga menguji jalur agent (bila `OPENAI_API_KEY` valid) dan `llm_tool_calls` di `coverage.checks_run`.
4. **Verifikasi pgx**: isi `DATABASE_URL` (session/direct string) di `backend/.env`, lalu jalankan scan dan cek log `data store: pgx direct Postgres`. Tanpa itu jalur pgx belum diuji terhadap Postgres sungguhan (unit test hanya memverifikasi fallback + simple protocol). Jalur `InsertPhoneReport`/`PhoneReportExists` versi pgx juga baru teruji di level kode.
5. **Aktifkan checkpointing**: terapkan `infra/supabase/migrations/202610300002_langgraph_schema.sql` di hosted SQL Editor, set `DATABASE_URL_SESSION`, lalu pastikan `langgraph_checkpointer` hilang dari `checks_unavailable`. Jangan jalankan ulang migrasi `0001`.
6. **Aktifkan integrasi opsional** sesuai kebutuhan: `EXA_API_KEY` (verifikasi klaim), `MOBSF_URL` + `MOBSF_API_KEY` (APK lebih dalam, tetap butuh consent per scan), `OPENAI_VISION_MODEL` (analisis gambar dengan vision). Semuanya sudah ada di kode dan muncul di `capabilities`.
7. Isi data awal `phone_reports`: tanpa laporan, phone scanner tetap `insufficient_evidence` (disengaja agar tidak menampilkan "aman" palsu). Moderasi masih manual lewat `PATCH /internal/v1/phone-reports/{id}`; belum ada UI moderator.
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
