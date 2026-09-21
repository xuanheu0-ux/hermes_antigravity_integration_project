# Hướng dẫn cài đặt chi tiết — Hermes + Antigravity 2.0

> Áp dụng cho bản đã sửa lỗi ngày 21/09/2026 (branch `arena/01a0c325-hermes-antigravity-integration`).
> Mọi lệnh dưới đây đều **copy-paste được**; đừng chạy lệnh ở bước sau khi bước trước chưa in ra
> dòng `ok:`. Toàn bộ script chỉ dùng `bash`, `docker`, `find`, `git` — không cần Python/Node trên máy host.

---

## 0. Yêu cầu tối thiểu

| Thành phần | Tối thiểu | Kiểm tra nhanh | Ghi chú |
|---|---|---|---|
| Docker Engine | 20.10+ (compose **v2**) | `docker compose version` | `docker-compose` (dấu gạch, v1) **không được hỗ trợ** |
| Nhân + RAM | 2 CPU, 8 GB RAM | `nproc`, `free -h` | Hermes cần 2 GB; Ollama + model 3B cần thêm ~4 GB khi nạp |
| Disk | ≥ 12 GB trống | `df -h ~` | image Hermes có Playwright+Node nên nặng (vài GB), model ~2 GB, chưa tính sessions/memory lớn dần |
| `git`, `curl` | bất kỳ | `git --version` | `git` cần cho indexer lấy thông tin repo |
| Antigravity | 2.0 Desktop hoặc CLI `agy` | `agy --help` | bản cũ dùng đường dẫn `.agent/` — xem bước 9 |
| Mạng | tới Docker Hub + `ollama.com` (registry model) | `docker pull hello-world` | máy chặn registry xem mục 11.4 |

Không cần cài Ollama, Python hay Node trên host: model chạy trong container sidecar.

### 0.1 Nếu đây là chiếc laptop trong `2026-06-02/summary.md` (i7-8650U, Ollama chạy bằng systemd)

Bạn cần dọn cấu hình cũ trước, nếu không sẽ có hai Ollama cùng giành cổng 11434:

```bash
# 1) Xem override cũ có còn dùng biến đã bị bỏ không (in ra dòng OLLAMA_NUM_CTX = đã chết)
systemctl cat ollama 2>/dev/null | grep -iE "num_ctx|context_length|host"

# 2) Sửa override: sudo systemctl edit ollama  -> dán:
#      [Service]
#      Environment="OLLAMA_CONTEXT_LENGTH=16384"
#      Environment="OLLAMA_HOST=0.0.0.0"
#      Environment="OLLAMA_KEEP_ALIVE=30m"
sudo systemctl daemon-reload && sudo systemctl restart ollama

# 3) Xác nhận biến đã thật sự vào process
systemctl show -p Environment ollama | tr ' ' '
' | grep OLLAMA_
```

Chọn **một** trong hai:
- **Ollama trên host** (vừa sửa ở trên): chạy `./start-hermes.sh` *không* có `--local-llm`, và
  `base_url=http://host.docker.internal:11434/v1`. `OLLAMA_HOST=0.0.0.0` là **bắt buộc** — mặc định
  Ollama chỉ nghe `127.0.0.1`, container gọi vào là `connection refused`.
- **Sidecar trong compose**: dừng Ollama trên host (`sudo systemctl stop --now ollama`) rồi
  `./start-hermes.sh --local-llm`. Nếu muốn giữ cả hai, đổi cổng publish: `OLLAMA_PORT=11435`
  trong `.env`, nếu không `docker compose up` sẽ báo
  `Bind for 127.0.0.1:11434 failed: port is already allocated`.

---

## 1. Lấy code **đúng branch đã sửa**

Code fix chưa nằm trên `main`. Chọn một trong hai cách:

```bash
# Cách A — clone trực tiếp branch đã sửa (nhanh nhất)
git clone -b arena/01a0c325-hermes-antigravity-integration \
  https://github.com/xuanheu0-ux/hermes_antigravity_integration_project.git
cd hermes_antigravity_integration_project

# Cách B — bạn đã clone từ trước (bản lỗi): nâng cấp tại chỗ
git fetch origin
git checkout arena/01a0c325-hermes-antigravity-integration
```

**Bắt buộc kiểm tra sau khi clone** (đây chính là lỗi làm dự án không build được trước đó —
`hermes-agent` từng bị commit dạng gitlink `160000` không có `.gitmodules`):

```bash
git ls-files -s hermes-agent        # phải in ra "100644 ... hermes-agent/Dockerfile" (NHIỀU dòng)
git submodule status; echo "rc=$?"  # phải là rc=0, KHÔNG báo "no submodule mapping found"
ls hermes-agent/Dockerfile          # phải tồn tại
```

Nếu `git ls-files -s hermes-agent` in ra `160000 ... hermes-agent` (một dòng duy nhất) ⇒ bạn đang ở
code cũ. Chạy `git rm --cached hermes-agent` rồi checkout lại branch ở trên.

---

## 2. Cài Docker (nếu chưa có)

**Linux (Debian/Ubuntu):**

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # để chạy docker không cần sudo — RẤT nên làm
newgrp docker                     # hoặc logout/login lại
docker compose version            # phải in ra "Docker Compose version v2.x"
```

> Không dùng `sudo docker ...` để chạy dự án này: volume `hermes_data` sẽ bị root sở hữu và
> container (`hermes` UID 10000) không ghi được vào `/opt/data`.

**macOS / Windows:** cài Docker Desktop, bật WSL2 backend trên Windows, và chắc chắn Docker
Desktop đang chạy (biểu tượng xanh) trước khi chạy script.

---

## 3. Tạo file cấu hình `.env`

```bash
cp .env.example .env
```

Chỉ 4 khoá sau là bạn **bắt buộc phải để ý**; còn lại giữ nguyên được:

| Khoá | Mặc định | Khi nào phải sửa |
|---|---|---|
| `HERMES_DROPZONE` | `./hermes_shared_workspace` | sửa nếu bạn muốn trỏ tới thư mục khác (đường dẫn tương đối tính từ thư mục repo, hoặc tuyệt đối) |
| `OLLAMA_MODEL` | `llama3.2:3b` | khi máy khỏe, đổi sang model code tốt hơn (xem 11.3) |
| `OLLAMA_CONTEXT_LENGTH` | `16384` | **đừng hạ xuống**; nhỏ hơn ~12k là hệ thống prompt của Hermes bị cắt |
| `HERMES_TIMEOUT` | `300` | tăng lên `900` nếu CPU yếu / model to |

`GEMINI_API_KEY` để trống là **đúng chủ đích** — mặc định chạy local 100% không tốn tiền API.
`.env` đã nằm trong `.gitignore`, đừng commit.

---

## 4. Chuẩn bị "drop zone" (phần quyết định tốc độ)

Drop zone là **thư mục chứa symlink** tới những repo bạn muốn Hermes biết. Đây là bước hay bị làm sai
nhất: mount cả `~/Documents/vscode` chính là nguyên nhân khiến token đầu tiên mất ~3 phút.

```bash
mkdir -p hermes_shared_workspace
ln -s ~/Documents/vscode/Dien-sc              hermes_shared_workspace/
ln -s ~/Documents/vscode/EVN_BaoCaoVanHanhThuyDien hermes_shared_workspace/
ln -s ~/Documents/vscode/deepseek-harness     hermes_shared_workspace/

# Kiểm tra: indexer phải liệt kê được chúng và loại node_modules/.git/venv
./scripts/hermes-index.sh
cat hermes_shared_workspace/INDEX.md | head -30
```

Quy tắc:

- ** symlink, không copy.** Copy sẽ cũ sau 1 tuần và Hermes sẽ trả lời sai một cách tự tin.
- **Chỉ 3–10 project.** Hermes không cần biết hết mọi thứ; nó cần biết đúng cái bạn hay hỏi.
- `.env`, `*.pem`, `credentials*` đã nằm trong danh sách loại (`hermes-agent/dropzone/.hermesignore`);
  nhưng đừng biến drop zone thành nơi chứa repo có secret thô.
- Mỗi lần thêm/bớt project: chạy lại `./start-hermes.sh --reindex`.

> Lưu ý quan trọng: file `.hermesignore` **không phải** tính năng của Hermes (upstream chưa implement —
> chỉ là proposal #502/#681/#50165). Nó được `scripts/hermes-index.sh` của repo này đọc. Sửa nó mà
> không chạy lại indexer thì coi như không sửa gì.

---

## 5. Khởi động

```bash
./start-hermes.sh --local-llm
```

Script tự làm 8 việc, in `ok:` cho từng bước:

1. preflight: `docker` có trên PATH, daemon trả lời, có **compose v2**;
2. tạo `.env` nếu thiếu; kiểm tra `docker-compose.yml` hợp lệ (`compose config`);
3. chặn checkout cũ còn gitlink lỗi (báo đúng lệnh sửa);
4. tạo drop zone + seed `AGENTS.md` (nhân cách "thủ thư repo") và `.hermesignore`;
5. build `INDEX.md`;
6. `docker compose --profile local-llm up -d` (pull image `nousresearch/hermes-agent` + `ollama/ollama`);
7. chờ `hermes` trong container trả lời `--version` (thay vì sleep cố định);
8. nạp model, rồi **nối provider**: `model.provider=custom`, `model.base_url=http://ollama:11434/v1`,
   `model.default=<OLLAMA_MODEL>`, `model.api_key=none`, cộng hai khoá chống phình prompt
   `terminal.cwd=/workspace/projects` và `context_file_max_chars=6000`.

Lần đầu sẽ tải ~3.5 GB ⇒ kiên nhẫn. Muốn bỏ qua bước tải model: `--no-pull`.

Các biến thể:

```bash
./start-hermes.sh                 # không chạy Ollama sidecar (bạn tự lo provider — xem 11.2)
./start-hermes.sh --local-llm --build   # build image phái sinh (seed sẵn trong image)
./start-hermes.sh --logs          # xem log container
./start-hermes.sh --down          # dừng
```

---

## 6. Hoàn tất provider (bắt buộc 1 lần, nếu chưa dùng `--local-llm`)

`--local-llm` đã tự nối endpoint cho bạn; vẫn nên xác nhận và chỉnh bằng wizard một lần:

```bash
docker exec -it hermes_local hermes setup      # wizard đầy đủ
# hoặc chỉ đổi model/provider:
docker exec -it hermes_local hermes model
```

Điền:

- Provider: **Custom endpoint**
- Base URL: `http://ollama:11434/v1` (dùng sidecar) hoặc `http://host.docker.internal:11434/v1` (Ollama trên host)
- API key: để trống hoặc gõ `none`
- Model: đúng tag `ollama list` in ra (mặc định `llama3.2:3b`)

Kiểm tra cấu hình thật sự đã ghi:

```bash
docker exec hermes_local hermes config get model.base_url   # -> http://ollama:11434/v1
docker exec hermes_local hermes config get terminal.cwd     # -> /workspace/projects
```

---

## 7. Kiểm tra sau cài đặt (5 lệnh, ~2 phút)

```bash
# 7.1 Sức khoẻ toàn chuỗi — phải "0 fail"
./start-hermes.sh --check

# 7.2 Hermes gọi được model? (khỏi container, không phải từ host)
docker exec hermes_local curl -s http://ollama:11434/v1/models | head -c 200

# 7.3 Cửa sổ context THỰC đang cấp phát (phải ≥ 16384, không phải 4096!)
docker exec hermes_ollama ollama ps

# 7.4 Hệ thống prompt bao nhiêu token (càng nhỏ càng nhanh)
docker exec hermes_local hermes prompt-size

# 7.5 Hỏi thử — đây chính là lệnh /hermes gọi bên dưới
./scripts/hermes-ask.sh "liệt kê các project bạn thấy và stack của từng cái"

# 7.6 Xác nhận an toàn: Hermes KHÔNG ghi được vào repo của bạn
docker exec hermes_local touch /workspace/projects/probe 2>&1 | head -1   # phải báo Read-only
```

Đạt = `7.1` 0 fail, `7.3` hiện CONTEXT 16384 (hoặc hơn), `7.5` in ra danh sách khớp `INDEX.md`.

Mã lỗi của `hermes-ask.sh`: `0` có câu trả lời · `1` rỗng · `2` lượt chạy lỗi/hết giờ ·
`3` container chưa chạy · `4` thiếu cấu hình · `130` bị interrupt.

---

## 8. Cấp quyền cho Antigravity 2.0

1. Mở **đúng thư mục repo này** làm workspace (không phải thư mục cha) — Antigravity chỉ nạp
   `.agents/` của workspace root.
2. Gõ `/` trong ô chat: phải thấy **`/hermes`**. Nếu không thấy:
   - kiểm tra `ls .agents/workflows/hermes.md` và `ls .agents/skills/hermes/SKILL.md`;
   - restart IDE một lần để nó quét lại skills;
   - bản Antigravity cũ tìm `.agent/` (số ít) ⇒ copy tạm (giữ nguyên file `.agents/` làm bản gốc):

     ```bash
     mkdir -p .agent && cp -r .agents/workflows .agents/rules .agents/skills .agent/
     ```
     *Không* tạo symlink `.agent -> .agents`: IDE sẽ nạp trùng toàn bộ rule.*
3. Dùng thử:

   ```
   /hermes project nào của tôi đã có sẵn code đọc đồng hồ điện theo khung giờ, và nó parse định dạng gì?
   ```

4. Skill nào cũng chỉ gọi `./scripts/hermes-ask.sh` — nếu muốn tự động hoá ngoài IDE (cron, CI,
   git hook) thì gọi thẳng script, đừng gọi `docker exec` tay.

**Dùng cho mọi project (toàn cục):**

```bash
# Skills toàn cục
mkdir -p ~/.gemini/config/skills && cp -r .agents/skills/hermes ~/.gemini/config/skills/
# Workflows toàn cục (build cũ)
mkdir -p ~/.gemini/antigravity/global_workflows && cp .agents/workflows/hermes.md ~/.gemini/antigravity/global_workflows/
```

Nếu gọi từ thư mục khác, nhớ truyền `--container`/`--cwd` hoặc đặt `HERMES_*` trong env của bạn,
vì script đọc `.env` **của repo này**.

---

## 9. Tuỳ chọn: dashboard, HTTP API, image riêng

**Web dashboard (chỉ loopback):**

```bash
sed -i 's/^HERMES_DASHBOARD=.*/HERMES_DASHBOARD=1/' .env
docker compose up -d hermes
# mở http://127.0.0.1:9119  — ĐỪNG đổi thành 0.0.0.0: trong /opt/data có API key
```

**Transport HTTP** (nhanh hơn khi hỏi liên tục, không spawn process mỗi lần):

```bash
openssl rand -hex 32                      # lấy 1 chuỗi làm key
# .env: HERMES_TRANSPORT=http, HERMES_API_ENABLED=true, HERMES_API_KEY=<chuỗi trên>
docker compose up -d --force-recreate hermes
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8642/v1/models | head -c 120
```

**Image phái sinh** (thêm tool apt, seed config ngay trong image):

```bash
./start-hermes.sh --build     # = docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

`hermes-agent/Dockerfile` chỉ overlay lên image chính thức. **Không** tự ý thêm `entrypoint:`/`user:`
vào service trong compose — image dùng s6-overlay (`/init`) để supervise gateway, chown `/opt/data`
và reap zombie; bỏ nó là gateway mất giám sát + rò rỉ process `<defunct>`.

---

## 10. Cập nhật & gỡ

```bash
# Cập nhật image Hermes (giữ nguyên toàn bộ cấu hình/memory, vì tất cả ở volume hermes_data)
docker compose pull hermes && docker compose up -d hermes && ./start-hermes.sh --check

# Quét lại project sau khi bạn đổi repo
./start-hermes.sh --reindex

# Xóa mềm (giữ dữ liệu)
./start-hermes.sh --down

# Xóa sạch: MẤT history/session/memory của Hermes
docker compose down -v
rm -rf hermes_shared_workspace
```

Backup trước khi đổi máy: `docker exec hermes_local hermes backup` (file `HERMES_HOME=/opt/data`).

---

## 11. Sự cố thường gặp

**11.1 `docker compose build` / `up` chết ngay, hoặc `git submodule status` báo "no submodule mapping found"**
⇒ bạn đang ở code cũ (gitlink lỗi). Xem bước 1.

**11.2 `connection refused` khi gọi 11434**
⇒ Ollama trên host chỉ nghe `127.0.0.1`, container không tới được. Chọn 1 trong 2:
- dùng sidecar: `./start-hermes.sh --local-llm` (khuyên dùng);
- hoặc trên host: `OLLAMA_HOST=0.0.0.0` (systemd: xem mục 0.1), rồi
  `base_url=http://host.docker.internal:11434/v1`;
- và lỗi đi kèm thường gặp: `port is already allocated` trên 11434 ⇒ host Ollama và sidecar
  đang giành cổng. Bỏ `--local-llm`, hoặc đặt `OLLAMA_PORT=11435` trong `.env`.

**11.3 Hermes trả lời lan man, "quên" chỉ dẫn (amnesia)**
⇒ context bị cắt. **Không dùng `OLLAMA_NUM_CTX`** — biến đó đã bị bỏ và endpoint `/v1` vứt
`num_ctx` dù bạn có gửi. Phải đặt ở server:

```bash
sed -i 's/^OLLAMA_CONTEXT_LENGTH=.*/OLLAMA_CONTEXT_LENGTH=32768/' .env
docker compose up -d --force-recreate ollama
docker exec hermes_ollama ollama ps      # CONTEXT phải = 32768
```
Model 3B + 16k context là mức hợp lý cho CPU yếu; lên 32k sẽ chậm hơn nhưng ít "quên" hơn.

**11.4 Token đầu tiên mất hàng phút**
(a) thu nhỏ drop zone về vài project; (b) `./start-hermes.sh --reindex`;
(c) `docker exec hermes_local hermes prompt-size` để xem token nằm ở đâu;
(d) giảm model về `llama3.2:3b`, hoặc tắt tool không cần (browser/Playwright) — browser là thứ ngốn RAM nhất.

**11.5 `Permission denied` trong container / Hermes không ghi được session**
⇒ bạn dùng bind mount `/opt/data` với UID khác. **Không** viết `HERMES_UID=$(id -u)` vào `.env` —
compose không thực thi command substitution trong file `.env`, nó sẽ truyền nguyên chuỗi `$(id -u)`.
Hãy ghi số thật vào file:

```bash
printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
docker compose up -d --force-recreate hermes
```

**11.6 `env file ... ./.env not found`** ⇒ quên bước 3 (`cp .env.example .env`).

**11.7 "Hermes không biết project X"** ⇒ X không có trong `hermes_shared_workspace/INDEX.md`.
Thêm symlink → `--reindex`. Đừng tin `.hermesignore` sẽ tự giải quyết (mục 4).

**11.8 Pull image bị timeout/chặn mạng** ⇒ Docker Hub không tới được. Thêm mirror trong
`/etc/docker/daemon.json` (`{"registry-mirrors":["https://<mirror>"]}`) rồi restart docker;
hoặc tải image ở máy khác: `docker save nousresearch/hermes-agent:latest | gzip > h.tgz` →
`gunzip -c h.tgz | docker load`.

**11.9 Windows**
- chạy trong **WSL2** là đỡ khổ nhất (Docker Desktop WSL backend, symlink hoạt động như Linux);
- PowerShell ngoài Windows: `New-Item -ItemType SymbolicLink -Path hermes_shared_workspace\Dien-sc -Target ..\..\Dien-sc` (cần Developer Mode);
- `HERMES_DROPZONE` dạng `D:/dev/hermes_shared_workspace`;
- host Ollama → `http://host.docker.internal:11434/v1` hoạt động sẵn, không cần `extra_hosts`.

**11.10 `/hermes` không hiện trong menu** ⇒ xem bước 8; ngoài ra workflow/skill phải có frontmatter
đúng (`description:` cho workflow, `name:` + `description:` cho skill).

---

## 12. Checklist 60 giây (bản rút gọn)

```bash
git clone -b arena/01a0c325-hermes-antigravity-integration \
  https://github.com/xuanheu0-ux/hermes_antigravity_integration_project.git
cd hermes_antigravity_integration_project
cp .env.example .env
mkdir -p hermes_shared_workspace
ln -s ~/Documents/vscode/<repo-cua-ban> hermes_shared_workspace/
./start-hermes.sh --local-llm
docker exec -it hermes_local hermes setup          # nếu wizard chưa được nối sẵn
./start-hermes.sh --check                          # phải "0 fail"
./scripts/hermes-ask.sh "tôi có project nào giải quyết X chưa?"
```
