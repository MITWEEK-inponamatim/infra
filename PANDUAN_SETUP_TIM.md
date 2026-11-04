# 🚀 Panduan Setup Lokal Proyek (Untuk Teman Tim)

Dokumen ini berisi panduan langkah demi langkah untuk menjalankan seluruh layanan ThreatLens di komputer lokal menggunakan Docker.

---

## 📌 Prasyarat

Sebelum memulai, pastikan perangkat Anda sudah terinstall:
1. **[Docker Desktop](https://www.docker.com/products/docker-desktop/)** — pastikan aplikasi sudah dibuka dan statusnya **Running**.
2. **Git** — sudah terinstall di sistem.

---

## 📁 Langkah 1: Clone 4 Repo ke Dalam 1 Folder Sejajar

Buka terminal (**PowerShell** atau **Terminal**), buat satu folder induk baru (misalnya `mitweek`), lalu clone keempat repositori ke dalamnya:

```powershell
mkdir mitweek
cd mitweek

git clone https://github.com/MITWEEK-inponamatim/infra.git
git clone https://github.com/MITWEEK-inponamatim/frontend.git
git clone https://github.com/MITWEEK-inponamatim/backend.git
git clone https://github.com/MITWEEK-inponamatim/analysis-service.git
```

> [!IMPORTANT]
> Pastikan posisi keempat folder berada di tingkat yang sama (**sejajar**), bukan saling bersarang:
> ```text
> mitweek/
> ├── infra/
> ├── frontend/
> ├── backend/
> └── analysis-service/
> ```

---

## 📄 Langkah 2: Buat File `.env` dari Template `.env.example`

Jalankan perintah berikut di PowerShell dari folder `mitweek`:

```powershell
Copy-Item frontend\.env.example frontend\.env
Copy-Item backend\.env.example backend\.env
Copy-Item analysis-service\.env.example analysis-service\.env
Copy-Item infra\supabase\.env.example infra\supabase\.env
```

---

## 🔑 Langkah 3: Isi Nilai `.env`

Buka file `.env` yang baru dibuat pada editor (VS Code, Notepad, dll.) dan lengkapi nilainya:

> [!CAUTION]
> Nilai kredensial/API key bersifat rahasia. Minta nilai-nilai ini kepada ketua tim melalui jalur komunikasi pribadi (bukan grup publik).

### 1. `frontend/.env`
- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
- `NEXT_PUBLIC_TURNSTILE_SITE_KEY`
- `NEXT_PUBLIC_API_BASE_URL=http://localhost:8080`
- `NEXT_PUBLIC_IDLE_TIMEOUT_SECONDS=3600`

### 2. `backend/.env`
- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SECRET_KEY`
- `SUPABASE_JWT_SECRET`
- `TURNSTILE_SECRET_KEY`
- `SERVICE_API_KEY` *(Wajib sama persis dengan yang di analysis-service/.env)*
- `PRE_COOKIE_SECRET`

### 3. `analysis-service/.env`
- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY`
- `SERVICE_API_KEY` *(Wajib sama persis dengan yang di backend/.env)*
- `OPENAI_API_KEY`
- `SAFE_BROWSING_API_KEY`
- `VIRUSTOTAL_API_KEY`
- `EXA_API_KEY`

---

## ⚙️ Langkah 4: Generate File Kunci Worker Otomatis

File `.env.browser` dan `.env.worker` **tidak ada di repo** dan harus diturunkan secara kriptografis (HMAC) dari `SERVICE_API_KEY`.

Buka PowerShell, masuk ke folder `infra`, lalu jalankan skrip berikut:

```powershell
cd infra

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

> [!NOTE]
> Perintah di atas akan otomatis membuat file `analysis-service/.env.browser` dan `analysis-service/.env.worker`.

---

## 🐳 Langkah 5: Jalankan Proyek dengan Docker Compose

Dari folder `infra`, jalankan perintah berikut:

```powershell
docker compose up --build
```

*(Atau jika Anda sedang berada di folder root `mitweek`: `docker compose -f infra/docker-compose.yml up --build`)*

Docker akan otomatis:
1. Men-download base image yang dibutuhkan.
2. Meng-install dependensi (Go, Python, Node.js) langsung di dalam container.
3. Menjalankan seluruh container secara otomatis dan terisolasi.

---

## 🌐 Langkah 6: Akses Aplikasi

Tunggu hingga seluruh container menampilkan status **healthy**, lalu buka di browser:
- **Frontend Web UI**: [http://localhost:3000](http://localhost:3000)
- **Backend API**: [http://localhost:8080](http://localhost:8080)

