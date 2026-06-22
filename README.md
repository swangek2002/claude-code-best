# CCB for ACMLab viz — drop-in Claude Code agent + browser chat (DeepSeek **or** local Qwable)

This is the **integration layer** that adds a second agent — **CCB ("Claude
Code Best", the open-source Claude Code rebuild)** — to an ACMLab
neuroimaging-viz deployment, side-by-side with the existing opencode agent, plus
a **left-side chat box** in the web page so *any visitor who can reach the page
can drive either agent and run skills from the browser*.

**CCB's model is switchable.** It can run on **DeepSeek v4 pro** (paid API) or on
a **local Qwable-3.6 model** served by your own ollama (free, no API cost), and
within Qwable you can pick **大 / 中 / 小** sizes. Switch right in the browser
dropdown or with the `CCB_PROFILE` env var — see **§4 Switching models** below.
Two ways to get Qwable: **Version 1** connects to a Qwable already running on the
shared tesla server; **Version 2** installs Qwable locally on your own machine.

It does **not** re-host CCB itself (CCB is cloned at install time from its own
repo; it is "for learning/research, rights to Anthropic"). This repo is only the
**adaptation**: the launcher, the one bug-fix patch, the Flask chat routes, the
self-injecting chat widget, a skills-sync script, and an installer.

> **Honesty note.** Numbers below come from controlled experiments on *this*
> system (both agents on the same DeepSeek v4 pro, same skills, same prompts).
> Where an earlier impression turned out to be a measurement artifact, it's
> labeled as corrected. Don't read more into it than the data supports.

---

## 1. What you get

- A `💬 AGENT` panel on the left of the viz page — pick **Original · opencode**
  or **Claude Code Best**, type an instruction, watch it run skills.
- opencode runs **deepseek-v4-pro**; **CCB's model is switchable** — DeepSeek or
  local Qwable 大/中/小 (see §4). Both keep independent sessions and run in the
  project dir (so they see `CLAUDE.md` + your skills and can curl localhost).
- **Async job model** (`POST /api/chat` → `GET /api/chat/poll`): a slow skill
  turn (ssh/scp, minutes) never freezes the single-threaded Tornado page.

---

## 2. CCB vs the opencode agent — mechanisms & measured behavior

Both agents are real harnesses (opencode also has compaction, retries, tool-call
repair, task subagents, a plan mode). The differences that **showed up in
testing on this system**:

### 2a. Measured results (same model, same skills)

| Test | opencode | CCB | verdict |
|---|---|---|---|
| **Skill triage** ("segment T1" → pick `synthseg`, not `slicer`), 5 trials | 5/5 correct, ~6s | 5/5 correct, ~6s | **tied** |
| **Templated skill exec** (NiiVue T1+seg overlay) | correct, drives the REST API | correct, drives the REST API | **tied** |
| **Anti-fabrication** (open a segmentation for a **non-existent subject**), 6 trials | **3/6 honest, 3/6 FABRICATED** ("Done, loaded" for data that isn't there) | **6/6 honest** (searches, reports it's missing, offers to fix) | **CCB clearly more reliable** |

**Corrected claims (don't repeat the early version):** a first run looked like
"CCB 3.6× faster / opencode flails 5 min" — that was a **measurement artifact**
(warm-up / a transient). On clean repeats, speeds are comparable. Likewise, much
of the "opencode feels dumb" impression on this system traced to a **permission
hang** in opencode's headless mode (it blocked on a permission prompt for an
external skill dir). That is a config bug, fixed by setting `"permission":
"allow"` in opencode's config — *not* a model/harness weakness.

**Important limitation for visual skills:** *neither* agent can see rendered
images, so on a viz skill both will report "done" from the script/API succeeding.
Only a **human (or a vision-capable checker)** can confirm a brain render is
actually correct. The CCB honesty advantage holds for *checkable preconditions*
(does the input file exist?), not for un-seeable render quality.

### 2b. Mechanisms CCB has that opencode reinforces less

These are CCB harness features (verified by reading CCB's source) that bear on
reliability for a clinical/agentic workflow:

1. **Verify-before-reporting + anti-fabrication prompt guardrails.** CCB's system
   prompt explicitly requires verifying a task actually worked before reporting
   complete, and forbids claiming success when output shows failure. This is the
   mechanism behind the 6/6-vs-3/6 anti-fabrication result.
2. **Dedicated verification subagent** with an adversarial contract (lists the
   model's own "verification-avoidance" failure modes, requires real command
   output, emits `VERDICT: PASS/FAIL/PARTIAL`). opencode has task subagents but
   no equivalent verification contract.
3. **Five-stage context compaction** (tool-result budget → snip → microcompact →
   context-collapse → autocompact) + *predictive* autocompact + a failure
   circuit-breaker. Keeps long, multi-step skill sessions from overflowing.
4. **Layered error-recovery state machine** — withhold-then-recover for
   413/max-output-tokens, model fallback that strips thinking signatures,
   tool_use/tool_result pairing guards so a crashed turn stays API-legal.
5. **Tool-result shaping** — oversized outputs are spilled to disk with a
   preview + path (so the model can re-read), keeping context small without
   losing information.
6. **Stop-hook "keep working" loop** — won't quietly stop with a task half-done
   if a stop hook flags it, with death-spiral guards.
7. **Memory system** (persistent project memory + background extraction) and
   **skill progressive disclosure** (only skill names/descriptions in context;
   full SKILL.md loaded on demand).

**Bottom line for deployment managers:** on simple one-shot skill calls, CCB and
opencode are equivalent — the shared `CLAUDE.md` does the work. CCB's edge is
**reliability/honesty** (it doesn't claim success it can't back up) and a richer
harness whose value grows on **harder, longer, multi-step or autonomous** tasks.
If your users mostly fire single skill calls, the bigger win is often just fixing
opencode's permission hang. Offer CCB as the option for users who want the
verification-heavy, less-fabricating agent.

---

## 3. Install (≈10 min + build)

**Prereqs:** `bun` ≥1.3.11 (`curl -fsSL https://bun.sh/install | bash`), your
viz `server.py` (Flask+Tornado), a DeepSeek API key, and your opencode running.

```bash
git clone <this-repo> ccb-deepseek-acmlab
cd ccb-deepseek-acmlab

# put your DeepSeek key in a 0600 file
umask 077; printf 'sk-...yourkey...' > ~/.deepseek_key

./install.sh \
  --project-dir /path/to/your/visualization \
  --keyfile     ~/.deepseek_key \
  --opencode    http://127.0.0.1:4097 \
  --skills-src  ~/.claude/skills        # your flat <skill>.md descriptors
```

The installer clones + patches + **builds CCB**, installs the launcher, syncs
your skills into CCB's format, and drops `ccb_chat.py` + `ccb-chat-widget.js`
into your project. It then prints the **two lines** you add by hand:

```python
# server.py  (after `app = Flask(__name__)` and PROJECT_DIR)
from ccb_chat import register_chat_routes
register_chat_routes(app, PROJECT_DIR)
```
```html
<!-- index.html, before </body> -->
<script src="/ccb-chat-widget.js"></script>
```

Restart your viz server, open the page → `💬 AGENT` on the left.

### Make opencode usable headlessly (recommended)
If your opencode side hangs on skill calls, add to your opencode config:
```json
{ "permission": "allow" }
```
(equivalent to CCB's `--dangerously-skip-permissions`; the chat box drives both
agents unattended, so neither can pause for a permission prompt.)

---

## 4. Switching models — DeepSeek ↔ Qwable (大 / 中 / 小)

The CCB agent's backend is chosen by a **profile**. Switch it three ways:

- **Browser:** pick *Claude Code Best* in the chat box → a **Model** dropdown
  appears, listing DeepSeek + the Qwable sizes actually installed.
- **CLI:** `CCB_PROFILE=qwable-medium ./scripts/ccb-agent.sh -p "…"`
- **Default:** set `CCB_DEFAULT_PROFILE=qwable-small` in the viz server env to
  make a profile the default for the browser box.

| Profile | Model | VRAM | Notes |
|---|---|---|---|
| `deepseek` | deepseek-v4-pro (cloud) | — | paid API; strongest on long/hard agentic tasks |
| `qwable-large` (大) | Qwable-3.6-**35b** Q8_0 | ~37 GB (needs 40GB+, e.g. 2×24GB) | best local quality |
| `qwable-medium` (中) | Qwable-3.6-**35b** Q4_K_M | ~21 GB (fits one 24GB GPU) | same 35B brain, faster |
| `qwable-small` (小) | Qwable-3.6-**27b** Q4_K_M | ~16 GB (fits one 24GB GPU) | smaller model, fastest |

All Qwable profiles talk to an **ollama OpenAI-compatible endpoint**, set by one
env var (the only thing that differs between the two versions below):

```bash
export QWABLE_OLLAMA_URL=http://127.0.0.1:11500/v1
```

### Version 1 — on the tesla server (Qwable already running)
Qwable is already installed and served on tesla (private ollama, port 11500).
You do **not** reinstall the model — just point CCB at the running endpoint:

```bash
# in your viz deployment ON tesla
export QWABLE_OLLAMA_URL=http://127.0.0.1:11500/v1   # the shared Qwable endpoint
# (re)start your viz server so ccb_chat.py picks it up
```
Then in the browser box: *Claude Code Best* → Model → **Qwable 大 / 中 / 小**.
CLI: `CCB_PROFILE=qwable-medium ./scripts/ccb-agent.sh -p "hello"`

> The shared daemon must be up. If the dropdown shows Qwable as *(not installed)*,
> (re)start it on tesla: `./scripts/qwable-serve.sh` — it's a per-user `nohup`
> daemon and does **not** survive a reboot.

### Version 2 — on your own machine (install Qwable locally)
One script installs an up-to-date ollama (no sudo), pulls the size(s), and starts
the daemon:

```bash
./install-qwable-local.sh --sizes "small medium"     # add "large" only if you have 40GB+ VRAM
export QWABLE_OLLAMA_URL=http://127.0.0.1:11500/v1
# (re)start your viz server
```
After a reboot, bring the daemon back with `./scripts/qwable-serve.sh`.
Requirements: Linux/amd64 + NVIDIA + `zstd`. (macOS: install the official ollama
app, `ollama pull` the tags in the table, then set `QWABLE_OLLAMA_URL`.)

### Which to use — honest guidance
On **simple / short** tasks (single skill calls, quick edits) Qwable is
competitive with DeepSeek and **free**. On **long, multi-step agentic** work
DeepSeek-v4-pro is clearly stronger (SWE-bench Verified 80.6 vs ~73.4 for the
Qwen3.6-35B base; tiny per-step error gaps compound over many tool calls).
Practical setup: **default to a Qwable size for cheap/high-volume work, switch to
`deepseek` for the hard tasks.** If you want the strongest *local* option, the
official `Qwen/Qwen3.6-35B-A3B` is a reasonable alternative to this community
finetune.

---

## 5. What's in here

```
backend/ccb_chat.py            Flask routes: /api/chat, /api/chat/poll, /api/chat/agents, /api/chat/models (async jobs + model switching)
frontend/ccb-chat-widget.js    self-injecting chat panel + CCB model dropdown (one <script> tag)
scripts/ccb-agent.sh           unified launcher: CCB on DeepSeek OR Qwable 大/中/小, selected by CCB_PROFILE
scripts/ccb-deepseek.sh        legacy launcher: CCB on DeepSeek only (kept for back-compat)
scripts/qwable-serve.sh        start/ensure a private ollama daemon serving the Qwable models
scripts/sync-skills.sh         convert flat ~/.claude/skills/*.md → CCB SKILL.md dirs
install-qwable-local.sh        Version 2: install ollama + pull Qwable size(s) locally (no sudo)
patches/openaiConvertMessages.patch   the DeepSeek 400 fix (thinking-only assistant turn)
install.sh                     orchestrates CCB build + launchers + assets (safe: copies + prints wiring lines)
```

### The one bug fix you must keep
CCB's OpenAI-compat layer serialized a *thinking-only* assistant turn as
`{content: null}` with no `tool_calls`, which DeepSeek rejects with
`400 Invalid assistant message: content or tool_calls must be set`. The patch
falls back to `content: ""` in that case. Without it, CCB+DeepSeek breaks on the
second turn of any tool-using conversation. (`patches/openaiConvertMessages.patch`)

---

## 6. Reproducing the comparison
The benchmark harness used for the numbers above (drivers for both agents, the
anti-fabrication test, the CDP/VNC screenshot tooling for human visual checks)
lives in the viz repo under `agent-benchmark/`. The full skill-by-skill
verification log is `agent-benchmark/SKILL_CAMPAIGN.md`.
