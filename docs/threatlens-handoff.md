# Handoff: Implementasi ThreatLens (Go + Python, REST API, Supabase)

Kamu adalah engineer yang mengimplementasikan **ThreatLens** ke dalam repo proyek ini. ThreatLens adalah platform deteksi ancaman berbasis AI yang menganalisis **URL, aplikasi (APK), nomor telepon, pesan, dan gambar** untuk mendeteksi phishing, scam, dan malware.

Dokumen ini adalah spesifikasi kerja. Ikuti alur dan batasan di bawah. Kalau ada yang bertentangan dengan kondisi repo, **cek repo dulu**, lalu sesuaikan dengan konvensi yang sudah ada dan catat penyesuaiannya di laporan akhir.

---

## 0. Cara kerja yang diminta

1. **Mulai dengan membaca repo.** Pahami struktur, framework frontend, router Go, konfigurasi, dan Dockerfile/compose yang sudah ada. Frontend sudah punya form untuk **tautan, pesan, APK, dan gambar**. Jangan dibuat ulang, tapi hubungkan ke API baru. Jangan asumsi.
2. Jangan membuat ulang yang sudah ada dan masih cocok. Pakai dan perluas.
3. Kerjakan **per fase** (bagian 12). Setiap fase harus bisa dijalankan dan dites sebelum lanjut.
4. Jangan hardcode secret. Semua lewat environment variable, dan sediakan `.env.example`.
5. Kalau ada keputusan yang benar-benar tidak bisa ditebak dari repo (lihat bagian 14), tanyakan. Untuk hal lain, ambil default yang masuk akal, tulis alasannya singkat, dan lanjut.
6. Setiap fase selesai: jalankan test dan linter, lalu beri ringkasan singkat (apa yang jadi, cara menjalankan, apa yang belum).

---

## 1. Arsitektur

Ada **dua backend** dengan peran berbeda, berkomunikasi lewat **REST API**, dan keduanya memakai **Supabase** sebagai platform data (Postgres, Auth, Storage).

```
Frontend ──HTTPS──▶ Go API (backend utama, publik)  ◀──▶ Supabase
   │                    │                                 ├─ Auth (Google OAuth)
   │ (login Google)     │ REST internal + service key     ├─ Postgres (+ RLS)
   └──────────────▶ Supabase Auth                         └─ Storage (private buckets)
                        ▼                                       ▲
                Python Analysis Service (FastAPI, internal saja)│
                  ├─ LangChain   (integrasi OpenAI + tool calling)
                  ├─ LangGraph   (orkestrasi, state, retry; checkpoint di Postgres)
                  ├─ Playwright  (browser worker terisolasi)
                  └─ FastAPI     (REST internal + background execution)
```

### Pembagian tanggung jawab

**Go (backend utama):**
- Satu-satunya pintu masuk API dari frontend (semua routing endpoint publik ada di sini).
- Verifikasi JWT Supabase, verifikasi Turnstile, manajemen sesi aplikasi dan idle timeout (bagian 3).
- Rate limiting, validasi awal input (tipe, panjang, ukuran file).
- Menerima upload file (APK, gambar), validasi, hitung SHA-256, simpan ke **Supabase Storage**.
- Membuat dan menyimpan record scan di **Supabase Postgres**, plus scan history.
- Memanggil Python service dan mem-polling statusnya, lalu menyajikan hasil ke frontend.
- Mencatat pemakaian LLM (tabel `llm_usage`) berdasarkan data yang dikembalikan Python.

**Python (analysis service):**
- Menjalankan scanner (URL, message, image, phone, application) lewat LangGraph.
- Memanggil OpenAI lewat LangChain dengan tool yang di-whitelist.
- Menjalankan Playwright di worker terisolasi.
- Membaca file dari Supabase Storage, menyimpan screenshot/artifact ke Storage, menyimpan state job di Postgres, dan memakai Postgres sebagai checkpointer LangGraph.
- Menyusun evidence dan risk assessment, lalu mengembalikan JSON sesuai kontrak.
- **Tidak** menangani login pengguna. Service ini internal dan tidak diekspos ke publik.

### Pola asinkron (wajib)

Scan bisa lama (browser, analisis APK), jadi **jangan pakai request-response sinkron**:

1. Go `POST` job ke Python, lalu Python membalas `202 Accepted` dengan `job_id`.
2. Python menjalankan scan di background dan memperbarui status di tabel `analysis_jobs`.
3. Go polling `GET` status job (interval 1–2 detik, backoff, ada batas waktu total) sampai `completed` atau `failed`, lalu menyimpan hasilnya ke `scans`.
4. Frontend polling endpoint publik Go dengan `scan_id` (polling ini **bukan aktivitas user**, lihat bagian 3.5).

---

## 2. Supabase

### 2.1 Peran Supabase

| Komponen | Dipakai untuk |
|---|---|
| **Auth** | Login Google OAuth (satu-satunya metode login) |
| **Postgres** | Semua data aplikasi, job state, checkpoint LangGraph, log LLM |
| **Storage** | Upload user (APK, gambar) dan artifact hasil scan (screenshot) |

Semua fungsi backend Go (routing endpoint, upload file, pencatatan LLM, history, sesi) terhubung ke Supabase lewat jalur di atas. Begitu juga keempat library di Python (FastAPI, LangChain, LangGraph, Playwright), lewat Storage dan Postgres seperti dijelaskan di bagian 2.5.

### 2.2 Konfigurasi dan koneksi

- Skema database dikelola dengan **Supabase CLI** (`supabase/migrations/`), di-commit ke repo. Kalau repo sudah punya sistem migrasi lain, sesuaikan dan catat.
- Go: koneksi Postgres lewat pooler Supabase. Untuk **transaction pooler**, pakai mode query yang kompatibel (tanpa prepared statement, mis. `simple_protocol` di pgx).
- Python: client Supabase (`supabase-py`) atau `httpx` untuk Storage, dan koneksi Postgres langsung (`psycopg`) untuk job state dan checkpointer. Checkpointer LangGraph (`langgraph-checkpoint-postgres`) memakai koneksi **session mode / direct**, bukan transaction pooler.
- Key yang kuat (`service_role` / secret key) **hanya di backend** (Go dan Python). Frontend hanya memakai URL + anon/publishable key. Jangan pernah ke bundle frontend atau log.

### 2.3 Tabel minimal

| Tabel | Isi utama |
|---|---|
| `profiles` | `id` (= `auth.users.id`), email, display_name, avatar_url, created_at |
| `scans` | id, user_id, type, input_ref, status, outcome, risk_level, report (JSONB), error, created_at, updated_at, finished_at |
| `files` | id, user_id, scan_id, bucket, storage_path, sha256, size_bytes, mime, created_at, expires_at |
| `analysis_jobs` | job_id, scan_id, type, status, progress, report (JSONB), error, created_at, updated_at (sumber kebenaran status job) |
| `app_sessions` | id, user_id, supabase_session_id, created_at, last_activity_at, revoked_at, revoked_reason, ip, user_agent |
| `auth_preflight` | nonce, created_at, expires_at, used_at, ip (bukti lolos Turnstile, sekali pakai) |
| `auth_events` | id, user_id, event (login, logout, idle_logout, turnstile_fail, jwt_invalid, ...), ip, user_agent, created_at |
| `llm_usage` | id, scan_id, model, prompt_tokens, completion_tokens, latency_ms, status, created_at (**tanpa** isi prompt atau respons) |
| `phone_reports` | id, number_e164, category, source, reported_by (nullable), status, created_at (laporan komunitas untuk phone scanner) |

Checkpoint LangGraph disimpan di schema terpisah (mis. `langgraph`) yang **tidak diekspos** lewat PostgREST/API Supabase.

### 2.4 Keamanan data: RLS dan Storage

- **Aktifkan RLS di semua tabel** schema `public`.
- `scans`, `files`, `profiles`: user hanya boleh `SELECT` baris miliknya (`user_id = auth.uid()`). Penulisan lewat backend.
- `app_sessions`, `auth_preflight`, `auth_events`, `llm_usage`, `analysis_jobs`: RLS aktif **tanpa policy** untuk role `anon`/`authenticated` (hanya backend yang mengakses).
- Bucket `uploads` dan `scan-artifacts`: **private**. Path objek `{user_id}/{scan_id}/{nama_file}`. Policy Storage: user hanya boleh baca objek di folder `user_id`-nya. Akses dari frontend lewat signed URL berumur pendek.
- Upload **dimediasi Go** (validasi magic bytes, ukuran, hash dulu, baru simpan ke Storage). Jangan izinkan upload langsung dari frontend ke bucket.
- Retensi: file upload dihapus otomatis setelah `FILE_RETENTION_DAYS` (konfigurasi, mis. 7 hari), lewat job terjadwal.
- Backend selalu menurunkan `user_id` dari **JWT yang sudah diverifikasi**, tidak pernah dari body request.

### 2.5 Integrasi Python dengan Supabase

- Python menerima `bucket` dan `storage_path` dari Go, **memverifikasi** bahwa path berawalan `{user_id}/{scan_id}/`, lalu mengunduh file dengan service key.
- Playwright menyimpan screenshot ke bucket `scan-artifacts` dan mengembalikan `screenshot_id` / path di laporan.
- `analysis_jobs` di-update oleh Python. Job tidak hilang walau Python restart.
- LangGraph memakai `PostgresSaver` (checkpointer) sehingga eksekusi graph bisa dilanjutkan atau diaudit.
- Phone scanner membaca `phone_reports` untuk laporan komunitas.
- Python mengembalikan metadata pemakaian LLM (model, token, latensi) di respons job. Go mencatatnya ke `llm_usage`.

### 2.6 Environment variable

`OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_TIMEOUT`, `OPENAI_MAX_RETRIES`,
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (frontend), `SUPABASE_SECRET_KEY` (backend saja),
`DATABASE_URL`, `DATABASE_URL_SESSION` (untuk checkpointer),
`TURNSTILE_SITE_KEY` (frontend), `TURNSTILE_SECRET_KEY` (Go saja),
`SERVICE_API_KEY` (antar-service Go ↔ Python),
`IDLE_TIMEOUT_SECONDS=3600`, `ABSOLUTE_SESSION_SECONDS=86400`,
`ALLOWED_ORIGINS`, `MAX_UPLOAD_MB`, `FILE_RETENTION_DAYS`,
`VIRUSTOTAL_API_KEY`, `SAFE_BROWSING_API_KEY`, `EXA_API_KEY` (tiga terakhir opsional).

---

## 3. Autentikasi dan sesi

### 3.1 Ketentuan

- **Hanya Google OAuth** lewat Supabase Auth. Tidak ada email/password, magic link, atau provider lain. Nonaktifkan semuanya di konfigurasi Supabase.
- **Cloudflare Turnstile** wajib di halaman `/login`.
- Auto logout setelah **idle 1 jam** (`IDLE_TIMEOUT_SECONDS=3600`).
- Semua halaman dan endpoint selain landing, `/login`, dan `/auth/callback` membutuhkan sesi valid.

### 3.2 Alur login (Authorization Code + PKCE)

1. User membuka `/login` (atau diarahkan ke sana, lihat bagian 4.1). Widget Turnstile dirender (`action: "login"`).
2. User menekan **"Masuk dengan Google"** (tombol nonaktif sampai token Turnstile ada). Frontend mengirim token ke Go: `POST /api/v1/auth/turnstile/verify`.
3. Go memverifikasi token ke endpoint `siteverify` Cloudflare dengan `TURNSTILE_SECRET_KEY`, `remoteip`, dan `idempotency_key`. Cek `success`, `hostname`, dan `action`. Kalau lolos, Go membuat `nonce` di `auth_preflight` dan mengirim cookie `tl_pre` (httpOnly, Secure, SameSite=Lax, berumur ±10 menit, ditandatangani).
4. Frontend memanggil `supabase.auth.signInWithOAuth({ provider: "google" })` dengan **PKCE** dan `redirectTo` ke `/auth/callback`.
5. `/auth/callback` menukar `code` menjadi sesi Supabase.
6. Frontend memanggil `POST /api/v1/auth/session/finalize`. Go memverifikasi JWT **dan** cookie `tl_pre` (belum dipakai, belum kedaluwarsa), menandai nonce `used_at`, lalu membuat baris `app_sessions` yang terikat ke `session_id` di JWT. Cookie `tl_pre` dihapus.
7. User diarahkan ke tujuan semula (`next`) atau ke halaman utama aplikasi.

**Penegakan:** semua endpoint API lain mewajibkan JWT valid **dan** `app_sessions` aktif. Tanpa `finalize` (artinya tanpa lolos Turnstile), API membalas `403 session_required`.

> Catatan: proteksi CAPTCHA bawaan Supabase tidak otomatis mencakup alur redirect OAuth. Itu sebabnya verifikasi Turnstile dilakukan di backend Go seperti di atas. Cek dokumentasi Supabase terbaru untuk memastikan perilaku ini sebelum implementasi dan catat temuannya.

### 3.3 Checklist standar industri

- OAuth 2.0 Authorization Code + **PKCE**. Jangan pakai implicit flow.
- Redirect URL di-allowlist ketat di Supabase dan Google Cloud Console (tanpa wildcard di produksi). Scope minimal: `openid email profile`.
- Hanya terima akun dengan **email terverifikasi** dari Google. Identitas utama = `sub` / `auth.users.id`, bukan email saja.
- Go memverifikasi JWT Supabase di **setiap request**: tanda tangan (JWKS dengan cache, atau secret sesuai konfigurasi proyek), `alg` yang diizinkan saja (tolak `none`), `iss`, `aud` (`authenticated`), `exp`, dan `session_id`. Jangan percaya claim yang belum diverifikasi.
- Pakai access token berumur pendek dan **refresh token rotation** (aktifkan di Supabase).
- Simpan sesi di **cookie httpOnly + Secure + SameSite** (kalau frontend SSR, mis. Next.js, pakai `@supabase/ssr`). Hindari menyimpan token di `localStorage`. Kalau memakai header `Authorization`, tokennya hanya di memori.
- Kalau memakai cookie untuk autentikasi API: proteksi **CSRF** (SameSite + token/pemeriksaan `Origin`) untuk request yang mengubah data.
- **CORS** dengan allowlist origin eksplisit, tanpa `*` bersama kredensial.
- **Security headers:** HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `frame-ancestors 'none'`, dan **CSP** yang mengizinkan Turnstile (`challenges.cloudflare.com`) dan Supabase saja.
- **Rate limiting** pada `/auth/*` (per IP dan per user), plus pencatatan percobaan gagal.
- **Logout** menutup sesi di sisi server: tandai `app_sessions.revoked_at`, panggil sign-out Supabase, hapus cookie.
- Pesan error autentikasi bersifat generik. Jangan bocorkan detail internal.
- Catat event penting ke `auth_events` (login, logout, idle_logout, turnstile_fail, jwt_invalid). Jangan log token atau secret.
- Validasi parameter `next` (bagian 4.1) untuk mencegah **open redirect**.

### 3.4 Auto logout idle 1 jam

**Server (otoritatif):**
- Middleware Go membandingkan `now - app_sessions.last_activity_at` dengan `IDLE_TIMEOUT_SECONDS`. Jika lewat: tandai sesi `revoked_reason = "idle"`, cabut sesi di Supabase, catat `idle_logout`, dan balas `401` dengan kode `session_expired_idle`. Sesi yang sudah dicabut ditolak walau JWT-nya masih valid.
- Update `last_activity_at` pada request yang dipicu user (di-throttle, mis. maksimal sekali per menit per sesi).
- Tambahkan juga batas **absolut** `ABSOLUTE_SESSION_SECONDS` (default 24 jam) sebagai pengaman.
- Opsional: kalau proyek Supabase mendukung (plan tertentu), aktifkan juga inactivity timeout / time-box sesi di pengaturan Supabase sebagai lapisan tambahan. Server Go tetap sumber kebenaran.

**Client:**
- Pantau aktivitas user: `pointerdown`, `keydown`, `scroll`, `touchstart`, `click`, plus kembalinya `visibilitychange`/`focus`. Simpan timestamp aktivitas terakhir (throttle ±30 detik).
- Timer idle membandingkan `Date.now()` dengan timestamp tersimpan, jangan hanya mengandalkan `setTimeout` (timer di tab latar bisa tertahan, dan laptop bisa sleep). Cek ulang saat tab kembali aktif.
- **Sinkron antar-tab** (`BroadcastChannel` atau event `storage`): aktivitas di satu tab memperpanjang semua tab, dan logout di satu tab mengeluarkan semua tab.
- Saat user aktif, kirim `POST /api/v1/auth/session/heartbeat` maksimal sekali per ±5 menit supaya `last_activity_at` di server tidak tertinggal.
- Tampilkan peringatan modal ±2 menit sebelum habis dengan tombol **"Tetap masuk"** (menghitung sebagai aktivitas dan memanggil heartbeat).
- Saat idle habis: `signOut`, bersihkan state dan cache sisi client, lalu arahkan ke `/login?reason=idle` dengan pesan yang jelas.

### 3.5 Polling bukan aktivitas

Polling status scan (dan permintaan otomatis lain) **tidak boleh memperpanjang sesi**. Kirim header `X-Activity: passive` pada request tersebut dan middleware Go tidak meng-update `last_activity_at` untuknya. Di client, polling juga tidak mereset timer idle.

---

## 4. Frontend

Gunakan framework dan komponen yang sudah ada di repo.

### 4.1 Landing dan pengalihan ke /login

- Landing boleh dilihat tanpa login, tapi untuk user **belum login**, **setiap interaksi** dialihkan dulu ke `/login`: klik pada teks atau elemen apa pun, submit form, dan klik tombol atau link navigasi apa pun (kecuali yang memang menuju `/login`). Scroll biasa **bukan** interaksi.
- Implementasi: pasang listener fase *capture* di root landing untuk `click`, `submit`, dan `keydown` (Enter/Space pada elemen interaktif). Panggil `preventDefault()` dan `stopPropagation()`, lalu arahkan ke `/login?next=<path-aman>`.
- Tambahkan juga **route guard di sisi server** (middleware frontend): semua rute selain landing, `/login`, dan `/auth/callback` yang diakses tanpa sesi valid diarahkan ke `/login`. Jangan mengandalkan JS client saja.
- **Validasi `next`:** hanya path relatif internal yang diawali satu `/` (bukan `//`, bukan URL absolut, tanpa skema), dan cocok dengan daftar rute yang diizinkan. Kalau tidak valid, pakai default.
- User yang sudah login dan membuka `/login` langsung diarahkan ke aplikasi.
- Jangan taruh input user (URL, pesan, nomor) di query string. Draft boleh disimpan sementara di `sessionStorage` (dihapus setelah dipakai atau setelah ±10 menit), dan **jangan** menyimpan file.

### 4.2 Halaman /login

- Tombol tunggal **"Masuk dengan Google"** dan widget Turnstile. Tidak ada form email/password.
- Tombol nonaktif sampai Turnstile menghasilkan token. Tangani token kedaluwarsa (reset widget) dan error Turnstile dengan pesan yang jelas.
- Tampilkan pesan sesuai `reason`: `idle` ("Sesi berakhir karena tidak ada aktivitas"), `session_required`, atau error OAuth.

### 4.3 Form scan (lima jenis)

Form yang sudah ada (**tautan, pesan, APK, gambar**) disambungkan ke endpoint baru. Tambahkan **form baru untuk cek nomor telepon**:

- Field nomor dengan pemilih kode negara (default `ID`/+62) dan validasi ringan di client. Normalisasi final dilakukan backend.
- Submit memanggil `POST /api/v1/scans/phone` dengan `{ number, default_region }`.
- Tampilkan state: mengirim, menunggu (polling dengan `X-Activity: passive`), selesai, dan gagal.
- Hasil memakai komponen laporan yang sama dengan scan lain: level risiko, confidence, coverage, temuan, rekomendasi, dan **keterbatasan** (nomor bisa dipalsukan, berpindah pemilik, laporan bisa keliru).
- Form APK menyertakan checkbox persetujuan `consent_external_upload` (default mati) dengan penjelasan singkat bahwa file bisa dikirim ke layanan pemindai eksternal.
- Pastikan kelima form memakai pola yang konsisten: validasi, loading, error, dan tampilan hasil.

### 4.4 Halaman lain

Riwayat scan (daftar dan detail), indikator sesi/idle, dan tombol logout.

---

## 5. Struktur direktori (sesuaikan dengan repo)

```
/backend-go/                 # atau mengikuti struktur Go yang sudah ada
  cmd/api/main.go
  internal/
    handler/                 # scans, uploads, history, auth
    service/                 # logika scan, sesi, turnstile
    client/analysis/         # HTTP client ke Python service
    client/supabase/         # JWT verify, Storage, admin sign-out
    repository/              # akses Postgres (Supabase)
    middleware/              # JWT, app_session + idle, rate limit, CORS, request id
    model/
    config/

/analysis-service/           # Python
  app/
    main.py
    api/
    core/                    # config, logging, service-key auth, supabase client
    schemas/                 # Pydantic: ScanRequest, Finding, ScanReport
    graph/                   # LangGraph: state, nodes, edges, checkpointer
    tools/                   # tool whitelist (lihat 7.3)
    scanners/                # url.py, message.py, image.py, phone.py, application.py
    browser/                 # Playwright worker + SSRF guard
    risk/                    # Risk Assessment Engine
    llm/                     # factory ChatOpenAI + prompt
  tests/
  Dockerfile

/supabase/
  migrations/                # skema, RLS, storage policies
  config.toml

/frontend/                   # mengikuti repo: landing, /login, /auth/callback, form scan, riwayat
```

Perbarui `docker-compose.yml` agar `go-api` dan `analysis-service` jalan bersama. Python service **tidak** boleh punya port yang dipublish ke host publik, cukup di network internal compose.

---

## 6. Kontrak REST API

### 6.1 API publik (Go → Frontend)

Semua di bawah `/api/v1`.

**Auth dan sesi**

| Method | Path | Fungsi |
|---|---|---|
| POST | `/auth/turnstile/verify` | Publik (rate limited). Body `{ "token": "..." }` → set cookie `tl_pre` |
| POST | `/auth/session/finalize` | Butuh JWT + `tl_pre`. Membuat `app_sessions` |
| POST | `/auth/session/heartbeat` | Perpanjang aktivitas saat user aktif |
| POST | `/auth/logout` | Cabut sesi |
| GET | `/me` | Profil user saat ini |

**Scan** (semua butuh JWT + sesi aktif)

| Method | Path | Fungsi |
|---|---|---|
| POST | `/scans/url` | Body `{ "url": "..." }` |
| POST | `/scans/message` | Body `{ "text": "..." }` |
| POST | `/scans/phone` | Body `{ "number": "...", "default_region": "ID" }` |
| POST | `/scans/image` | `multipart/form-data`, field `file` |
| POST | `/scans/application` | `multipart/form-data`, field `file`, plus `consent_external_upload` (bool) |
| GET | `/scans/{scan_id}` | Status dan hasil (milik user itu saja) |
| GET | `/scans` | Riwayat scan user (paginasi) |

Respons pembuatan scan: `202` dengan `{ "scan_id": "...", "status": "queued" }`.
Status scan: `queued | running | completed | failed`.

Kode error auth yang konsisten: `unauthenticated`, `session_required`, `session_expired_idle`, `session_expired_absolute`, `captcha_failed`, `rate_limited`.

### 6.2 API internal (Go → Python)

Semua endpoint wajib header `X-Service-Key` (dari env, dibandingkan secara constant-time). Tanpa itu → `401`.

| Method | Path | Fungsi |
|---|---|---|
| POST | `/internal/v1/jobs` | Buat job. Body: `{ "scan_id", "user_id", "type", "input": {...}, "options": {...} }`. Untuk file, `input` berisi `bucket`, `storage_path`, `sha256`. Balas `202` + `{ "job_id" }` |
| GET | `/internal/v1/jobs/{job_id}` | Status job, dan `report` + `llm_usage` kalau sudah selesai |
| GET | `/internal/v1/health` | Health check |

`type` ∈ `url | message | phone | image | application`.

### 6.3 Skema hasil (kontrak bersama Go dan Python)

Definisikan di Pydantic, ekspor OpenAPI, lalu buat struct Go yang sama persis.

```json
{
  "scan_id": "string",
  "type": "url",
  "outcome": "confirmed_threat | suspicious | insufficient_evidence | scan_failed",
  "risk": {
    "level": "low | medium | high | unknown",
    "score": null,
    "confidence": "low | medium | high",
    "coverage": {
      "checks_run": ["safe_browsing", "virustotal", "browser_inspection"],
      "checks_unavailable": ["exa_search"],
      "summary": "string"
    }
  },
  "findings": [
    {
      "id": "string",
      "indicator": "string",
      "source": "string",
      "severity": "info | low | medium | high | critical",
      "timestamp": "RFC3339",
      "confidence": "low | medium | high",
      "metadata": {},
      "limitations": "string"
    }
  ],
  "evidence_summary": "string",
  "recommended_actions": ["string"],
  "limitations": ["string"],
  "artifacts": { "screenshot_path": null, "redirect_chain": [] },
  "llm_usage": { "model": "string", "prompt_tokens": 0, "completion_tokens": 0, "latency_ms": 0 },
  "error": null
}
```

Aturan penting:
- **Risk, confidence, dan coverage dipisahkan.** Jangan digabung jadi satu angka.
- Tidak ada hasil di threat intelligence **bukan berarti aman**. Hasilnya `unknown` atau `insufficient_evidence`, bukan `low`, kecuali ada cukup bukti positif.
- `risk.score` boleh `null` selama belum dikalibrasi.
- Scan yang gagal → `outcome: scan_failed` dengan `error` yang jelas (mis. `scanner_not_implemented`, `timeout`), bukan error 500 tanpa konteks.

---

## 7. Python service: detail implementasi

### 7.1 Konfigurasi LLM (OpenAI)

- Provider: **OpenAI**, lewat `langchain-openai` (`ChatOpenAI`).
- Env: `OPENAI_API_KEY` (wajib), `OPENAI_MODEL` (**jangan di-hardcode**), `OPENAI_TIMEOUT`, `OPENAI_MAX_RETRIES`.
- Satu factory di `app/llm/`.
- Gunakan **structured output** (Pydantic schema), jangan parsing teks bebas.
- Kalau `OPENAI_API_KEY` kosong, service tetap start, scanner yang butuh LLM mencatat `llm_analysis` di `checks_unavailable`, dan tidak crash.
- Batasi ukuran konteks yang dikirim ke LLM (potong teks halaman, batasi jumlah form dan domain).
- Kumpulkan metadata pemakaian (model, token, latensi) untuk dikembalikan ke Go. **Jangan** menyimpan isi prompt/respons ke log atau tabel.

### 7.2 LangGraph (orkestrasi)

- Satu graph per scanner, dengan state bertipe: input, evidence terkumpul, findings, error, jumlah iterasi.
- Checkpointer: `PostgresSaver` di Supabase Postgres (bagian 2.5).
- Node = langkah deterministik (validasi, reputasi, browser, analisis LLM, risk). Edge kondisional untuk:
  - lanjut ke browser hanya kalau URL lolos validasi SSRF,
  - kirim URL hasil ekstraksi dari message/image ke graph URL,
  - **batas iterasi** jika LLM meminta pemeriksaan tambahan (maksimal 2–3 putaran).
- Retry dengan backoff untuk panggilan eksternal. Kegagalan satu sumber **tidak** menggagalkan seluruh scan, cukup dicatat di `checks_unavailable`.
- Timeout total per job (60–120 detik, bisa dikonfigurasi).

### 7.3 LangChain (tool calling)

LLM hanya boleh memanggil tool dari whitelist ini, dan **semua argumen divalidasi oleh backend**, bukan oleh prompt:

- `check_url_reputation(url)`
- `inspect_website(scan_id)`
- `get_page_metadata(scan_id)`
- `inspect_forms(scan_id)`
- `analyze_application(file_id)`
- `lookup_phone(number)`
- `analyze_message(text)`
- `extract_image_text(file_id)`
- `search_verification_evidence(claims)`

LLM **tidak** boleh punya akses shell, filesystem bebas, atau jaringan bebas. Tool menerima `scan_id`/`file_id`, bukan path atau URL sembarang, kecuali tool reputasi yang tetap melewati validasi.

### 7.4 Playwright (browser worker)

- Jalankan browser di **proses/worker terpisah** dari proses API, dengan context baru per scan dan dibuang setelahnya (tanpa cookie atau storage yang bocor antar scan).
- Kumpulkan: final URL dan redirect chain, title, teks yang terlihat, form beserta action/destination-nya, domain eksternal dan metadata request jaringan, screenshot (disimpan ke bucket `scan-artifacts`).
- **SSRF guard (wajib):**
  - Hanya `http`/`https`, port 80/443 (konfigurasi).
  - Resolve DNS, lalu tolak IP private, loopback, link-local, metadata cloud (`169.254.169.254`), dan rentang reserved. Berlaku untuk IPv4 dan IPv6.
  - Validasi ulang **setiap redirect dan setiap request subresource** (`page.route`), bukan hanya URL awal.
  - Waspadai DNS rebinding. Idealnya batasi egress di level container/network, jangan hanya mengandalkan cek di kode.
- Timeout navigasi, batas ukuran respons, batas jumlah request, batas durasi.
- Nonaktifkan download otomatis dan akses file lokal. Jalankan sebagai user non-root di container.
- Konten halaman = **input tidak tepercaya** (lihat 7.6).

### 7.5 Scanner dan sumber data eksternal

| Scanner | Sumber / tool |
|---|---|
| URL | Google Safe Browsing, VirusTotal, Playwright, analisis LLM |
| Message | Analisis LLM, ekstraksi indikator, Exa untuk verifikasi klaim, URL → URL scanner |
| Phone | Normalisasi dengan `phonenumbers`, layanan reputasi (jika ada), laporan komunitas dari tabel `phone_reports` |
| Image | OCR (default: `pytesseract` dengan bahasa `ind+eng`, sesuaikan jika repo punya pilihan lain), lalu alur Message, URL → URL scanner, vision model OpenAI opsional |
| Application | SHA-256, lookup hash (VirusTotal), analisis statis (MobSF / JADX / Apktool) untuk sampel tidak dikenal |

Aturan:
- Semua API key eksternal (VirusTotal, Safe Browsing, Exa) **opsional**. Kalau tidak ada, catat sebagai `checks_unavailable` dan jangan gagal.
- Hash lookup hanya reputasi, bukan reverse engineering. File tidak dikenal **tidak otomatis aman**.
- Upload file ke layanan eksternal hanya jika `consent_external_upload = true`. Tanpa itu, cukup lookup hash.
- Nomor telepon: validasi bukan bukti identitas. Laporan bisa salah, nomor bisa berpindah pemilik, dan caller ID bisa dipalsukan. Tulis ini di `limitations`.
- Hasil pencarian Exa **tidak otomatis membuktikan** suatu klaim. Pisahkan "indikator scam" dari "klaim faktual yang belum terverifikasi".
- Dynamic analysis APK (emulator/VM) hanya di Fase 4.

#### 7.5a Application scanner (tambahan)
- Ekstraksi fitur statis pakai Androguard (in-process, tanpa Java) di worker
  terisolasi: tanpa network, non-root, batas CPU/memori, timeout.
  APK tidak pernah dijalankan.
- Pre-check anti zip bomb: batas jumlah entry, total ukuran terdekompresi,
  rasio kompresi, dan ukuran per entry. Tolak jika melebihi batas.
- Fitur yang diekstrak: package name, label, versi, signer (hash sertifikat),
  permission, komponen manifest (activity/service/receiver/provider,
  intent filter), API sensitif (SMS, accessibility, install package,
  device admin, overlay), URL/IP/domain hardcoded, indikasi token bot
  Telegram, ikon launcher disembunyikan, native lib, indikasi packer atau
  dynamic code loading.
- Setiap fitur jadi finding (source=static_analysis). LLM hanya menerima
  ringkasan fitur dalam <untrusted_content>, bukan APK atau kode penuh.
- Aturan risk engine (contoh): SMS + accessibility/install package -> high;
  nama atau label tidak cocok dengan permission yang diminta -> naik;
  token bot Telegram hardcoded -> naik.
- MobSF/JADX opsional, sebagai service terpisah hanya untuk sampel tidak
  dikenal. Jika tidak tersedia, catat di checks_unavailable.
- Tidak ada indikator + analisis tidak lengkap (obfuscated/packed) ->
  insufficient_evidence, bukan low.

## 7.6 Perlindungan prompt injection

- Teks website, hasil OCR, dan kode hasil dekompilasi adalah **data tidak tepercaya**. Kirim ke LLM dalam blok yang jelas bertanda (mis. `<untrusted_content>`), dengan instruksi sistem bahwa isinya tidak boleh diperlakukan sebagai perintah.
- Output LLM selalu divalidasi terhadap schema. Jangan pernah mengeksekusi sesuatu hanya karena teks halaman memintanya.
- Keputusan akhir risiko dibuat oleh **risk engine (aturan di kode)**, bukan langsung oleh LLM. LLM menyumbang findings dengan bukti yang bisa ditelusuri.

### 7.7 Risk Assessment Engine

- Modul `app/risk/` yang murni deterministik dan mudah dites.
- Input: daftar findings. Output: `outcome`, `risk.level`, `risk.confidence`, `coverage`, `recommended_actions`, `limitations`.
- Aturan awal yang sederhana dan transparan (contoh: ada flag dari Safe Browsing/VirusTotal → naik ke `high`; form kredensial yang mengirim ke domain berbeda dengan klaim brand → naik; tidak ada bukti dan coverage rendah → `unknown`).
- Setiap finding mencatat `source` dan `timestamp` agar bisa diaudit.

---

## 8. Go backend: detail implementasi

- Ikuti router dan pola error handling yang sudah ada di repo.
- **Middleware berurutan:** request id → CORS/security headers → rate limit → verifikasi JWT → cek `app_sessions` (aktif, tidak idle, tidak melewati batas absolut) → handler.
- **Validasi input** sebelum memanggil Python:
  - URL: skema `http/https`, panjang maksimum, normalisasi dasar.
  - Message: panjang maksimum.
  - Phone: panjang dan karakter wajar, region dari daftar yang diizinkan.
  - File: batas ukuran, cek tipe berdasarkan **magic bytes** (bukan hanya ekstensi), APK harus ZIP valid, gambar harus format yang diizinkan.
- Hitung SHA-256 saat upload, lalu simpan file ke Storage dan metadata ke tabel `files`.
- **Client ke Python:** `http.Client` dengan timeout, `X-Service-Key`, retry terbatas hanya untuk error jaringan/5xx pada operasi idempoten, dan propagasi `X-Request-ID`.
- **Worker polling:** goroutine terkontrol (pakai `context`, batas konkurensi). Saat restart, scan berstatus `queued/running` yang tertinggal harus bisa dilanjutkan atau ditandai `failed` dengan jelas.
- Setelah job selesai: simpan laporan ke `scans`, catat `llm_usage`.
- Jangan pernah mengembalikan stack trace atau detail internal Python/Supabase ke frontend.

---

## 9. Keamanan dan infrastruktur (ringkasan wajib)

- Python service hanya dapat diakses dari Go (network internal + `X-Service-Key`).
- Browser worker dan file-analysis worker terisolasi dari proses API, dijalankan sebagai non-root, dengan batas CPU/memori dan timeout.
- Egress browser worker dibatasi (SSRF guard di kode **dan** di network).
- API key dan service-role key hanya di environment backend, tidak pernah ke frontend dan tidak masuk log.
- RLS aktif di semua tabel, bucket private, dan akses data selalu diturunkan dari `user_id` di JWT terverifikasi.
- Jangan kirim data pribadi yang tidak perlu ke API pihak ketiga (OpenAI, VirusTotal, Exa). Potong/mask bila memungkinkan.
- Log berisi `scan_id` dan `request_id`, tetapi **tanpa** isi pesan penuh, token, API key, atau isi file.
- Catat provenance evidence (sumber dan waktu) agar bisa diaudit.

---

## 10. Testing

**Auth dan sesi (Go):**
- JWT: tanda tangan salah, kedaluwarsa, `aud`/`iss` salah, `alg: none`, `session_id` tidak dikenal.
- Turnstile: token salah/kedaluwarsa/dipakai ulang, `hostname` atau `action` tidak cocok (pakai mock Cloudflare).
- `finalize` tanpa cookie `tl_pre`, dengan nonce kedaluwarsa, dan dengan nonce yang dipakai ulang → ditolak.
- Endpoint scan tanpa `app_sessions` → `403 session_required`.
- Idle: sesi > 1 jam tanpa aktivitas → `401 session_expired_idle`. Request polling (`X-Activity: passive`) **tidak** memperpanjang sesi. Request user memperpanjang sesi.
- Parameter `next`: `//evil.com`, `https://evil.com`, `javascript:`, path tidak ada di allowlist → ditolak.

**RLS dan Storage:**
- User A tidak bisa membaca `scans`, `files`, atau objek Storage milik user B. `anon` tidak bisa membaca apa pun.
- Tabel internal (`app_sessions`, `auth_preflight`, `llm_usage`, ...) tidak bisa diakses dari client.

**Frontend:**
- Landing tanpa login: klik teks, klik tombol navigasi, dan submit form masing-masing mengalihkan ke `/login`. Scroll tidak.
- Rute terproteksi tanpa sesi → `/login`. Setelah login → kembali ke `next` yang valid.
- Idle logout dengan fake timers: peringatan muncul, "Tetap masuk" memperpanjang, habis waktu → logout dan redirect `/login?reason=idle`, sinkron antar-tab.
- Form telepon: validasi, loading, hasil, dan error.

**Python:**
- Unit test risk engine (flag positif, tanpa bukti, coverage rendah, scan gagal).
- Unit test SSRF guard: `127.0.0.1`, `localhost`, `10.x`, `192.168.x`, `169.254.169.254`, IPv6 loopback, redirect ke IP internal, skema `file://`, `gopher://`.
- Scanner dengan mock untuk OpenAI, Supabase, dan API eksternal. Tes **tidak boleh** memanggil layanan asli.
- Alur graph, termasuk batas iterasi dan kegagalan sebagian sumber.
- Verifikasi path Storage (`{user_id}/{scan_id}/`) menolak path milik user lain.

**Integrasi:** skenario end-to-end via compose: login (Supabase lokal atau mock), scan URL dan message sampai hasil tersimpan di history.

---

## 11. Definition of Done (MVP)

- User hanya bisa memakai aplikasi setelah login **Google OAuth + Turnstile**, dan sesi berakhir otomatis setelah **idle 1 jam**.
- Landing mengalihkan semua interaksi user belum login ke `/login`.
- User bisa mengirim **URL atau pesan** (dan form telepon sudah tersedia di UI), sistem mengumpulkan evidence, menganalisis, dan mengembalikan laporan terstruktur yang tersimpan di Supabase.
- Laporan membedakan: ancaman terkonfirmasi, indikator mencurigakan, bukti tidak cukup, dan scan gagal.
- RLS dan bucket private terverifikasi lewat test.
- Sebelum produksi, sandbox browser dan pembatasan jaringan harus lolos security testing.

---

## 12. Fase implementasi

Kerjakan berurutan. **Berhenti dan laporkan setelah Fase 2** sebelum lanjut, supaya saya bisa review.

**Fase 1: Fondasi, Supabase, dan Auth**
- Struktur Go + Python service + Supabase CLI, docker-compose, `.env.example`.
- Migrasi: semua tabel (bagian 2.3), RLS, bucket dan policy Storage.
- Auth lengkap: Google OAuth (PKCE), Turnstile, `finalize`, `app_sessions`, idle logout (server dan client), logout, route guard, pengalihan landing ke `/login`.
- Skema hasil bersama dan kontrak REST (bagian 6).
- Go: endpoint scan URL/message/phone (phone dulu mengembalikan `scan_failed` dengan `scanner_not_implemented`), upload ke Storage, penyimpanan scan + history, client Python, polling.
- Python: endpoint internal, `analysis_jobs`, factory OpenAI, scanner Message dasar, reputasi URL, risk engine awal.
- Frontend: sambungkan form tautan dan pesan, tambahkan **form telepon** (UI final), tampilan hasil dan riwayat.
- *Selesai bila:* login Google + Turnstile berjalan, idle logout teruji, pesan bisa di-scan end-to-end dan tampil di history.

**Fase 2: Browser Intelligence**
- Playwright worker terisolasi + SSRF guard lengkap, screenshot ke Storage.
- Redirect chain, form, domain eksternal, analisis LLM berbasis evidence.
- Graph URL dengan batas iterasi, checkpointer Postgres, dan aturan risiko awal.
- *Selesai bila:* URL phishing contoh (lokal/mock) terdeteksi dan semua tes SSRF lolos.

**Fase 3: Scanner tambahan**
- Phone scanner sungguhan (normalisasi, reputasi, `phone_reports`), Image (OCR → Message → URL), Application (hash lookup + analisis statis), dan sambungkan form gambar, APK, dan telepon end-to-end.

**Fase 4: Analisis lanjutan**
- Verifikasi klaim dengan Exa, dynamic analysis APK, LangGraph kondisional lanjutan, kalibrasi skor, monitoring, dan hardening produksi.

---

## 13. Format laporan yang saya harapkan dari kamu

Setelah tiap fase, tulis singkat:
1. Apa yang dibuat (file/modul utama).
2. Cara menjalankan dan mengetes.
3. Keputusan/asumsi yang kamu ambil.
4. Yang belum dikerjakan atau berisiko.

---

## 14. Hal yang perlu dikonfirmasi bila tidak bisa disimpulkan dari repo

Cek repo dulu. Tanyakan hanya yang benar-benar belum jelas:
- **Routing:** default-nya semua routing API tetap di **Go**, dan Supabase dipakai untuk Auth, Postgres, dan Storage. Kalau maksudnya sebagian logika dipindah ke **Supabase Edge Functions**, konfirmasi dulu sebelum mengubah arsitektur.
- Framework frontend dan cara menyimpan sesi (cookie SSR atau token di memori).
- Apakah proyek Supabase sudah ada (URL, project ref) atau perlu setup lokal lewat Supabase CLI.
- Apakah repo sudah punya sistem migrasi lain yang harus dipertahankan.
- Cara berbagi file Go → Python (default: Python mengunduh dari Storage dengan service key).
- Nilai `OPENAI_MODEL` yang diinginkan.
- Apakah sudah ada job queue (mis. Redis). Default: **tanpa queue tambahan**, Python pakai background task + `analysis_jobs`, dan Go polling.
