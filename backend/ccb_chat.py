"""
ccb_chat.py — drop-in Flask routes that let any visitor of the viz web page
chat with EITHER the original opencode agent OR the CCB agent (open-source
Claude Code rebuild on DeepSeek), and run skills from the browser.

Portable across ACMLab tenant deployments. To install, add TWO lines to your
server.py (after `app = Flask(__name__)` and PROJECT_DIR are defined):

    from ccb_chat import register_chat_routes
    register_chat_routes(app, PROJECT_DIR)

Configuration is via env vars (with sensible defaults), so each tenant keeps
its own ports/paths without editing this file:

    CCB_LAUNCHER   path to ccb-deepseek.sh         (default: <project>/scripts/ccb-deepseek.sh)
    OPENCODE_BASE  your opencode HTTP base          (default: http://127.0.0.1:4097)
    OPENCODE_MODEL_PROVIDER / OPENCODE_MODEL_ID     (default: deepseek / deepseek-v4-pro)
    CHAT_TIMEOUT_S per-turn timeout seconds         (default: 900)

Design note — ASYNC JOB MODEL: a skill turn does ssh/scp and can take minutes.
The viz server is a single-threaded Tornado WSGI loop, so a blocking handler
would freeze the whole page for everyone. POST /api/chat starts a background
thread and returns a job_id immediately; the browser polls /api/chat/poll.
"""
import os
import json
import uuid
import threading
import subprocess
import urllib.request
import urllib.parse

from flask import request, jsonify


def register_chat_routes(app, project_dir, *,
                         ccb_launcher=None,
                         opencode_base=None,
                         opencode_model=None,
                         timeout_s=None):
    if not ccb_launcher:
        ccb_launcher = os.environ.get("CCB_LAUNCHER")
    if not ccb_launcher:
        # Prefer the unified profile launcher (supports deepseek + qwable sizes),
        # fall back to the legacy deepseek-only one for older installs.
        cand_agent = os.path.join(project_dir, "scripts", "ccb-agent.sh")
        cand_ds = os.path.join(project_dir, "scripts", "ccb-deepseek.sh")
        ccb_launcher = cand_agent if os.path.exists(cand_agent) else cand_ds
    opencode_base = opencode_base or os.environ.get(
        "OPENCODE_BASE", "http://127.0.0.1:4097")
    opencode_model = opencode_model or {
        "providerID": os.environ.get("OPENCODE_MODEL_PROVIDER", "deepseek"),
        "modelID": os.environ.get("OPENCODE_MODEL_ID", "deepseek-v4-pro"),
    }
    timeout_s = timeout_s or int(os.environ.get("CHAT_TIMEOUT_S", "900"))

    # Model switching for the CCB agent. A "profile" maps to a backend the
    # ccb-agent.sh launcher understands (via the CCB_PROFILE env var).
    qwable_url = os.environ.get("QWABLE_OLLAMA_URL", "http://127.0.0.1:11500/v1")
    default_profile = os.environ.get("CCB_DEFAULT_PROFILE", "deepseek")
    PROFILE_TAG = {   # profile -> ollama model tag (None for the cloud DeepSeek profile)
        "deepseek": None,
        "qwable-large": os.environ.get("QWABLE_LARGE_MODEL", "hf.co/Mia-AiLab/Qwable-3.6-35b:Q8_0"),
        "qwable-medium": os.environ.get("QWABLE_MEDIUM_MODEL", "hf.co/Mia-AiLab/Qwable-3.6-35b:Q4_K_M"),
        "qwable-small": os.environ.get("QWABLE_SMALL_MODEL", "hf.co/Mia-AiLab/Qwable-3.6-27b:Q4_K_M"),
    }

    jobs = {}                       # job_id -> {status, reply, session_id, agent, error, elapsed_s}
    jobs_lock = threading.Lock()

    def http_json(url, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(
            url, data=data, method="POST" if data is not None else "GET",
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            return json.loads(r.read().decode())

    def run_opencode(message, session_id):
        dq = "?directory=" + urllib.parse.quote(project_dir)
        if not session_id:
            session_id = http_json(opencode_base + "/session" + dq, {})["id"]
        body = {"parts": [{"type": "text", "text": message}], "model": opencode_model}
        res = http_json(opencode_base + "/session/" + session_id + "/message" + dq, body)
        parts = res.get("parts", []) if isinstance(res, dict) else []
        reply = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text").strip()
        return reply or "(no text reply)", session_id

    def run_ccb(message, session_id, profile):
        env = dict(os.environ)
        env["CCB_PROFILE"] = profile            # ccb-agent.sh selects the backend from this
        env["QWABLE_OLLAMA_URL"] = qwable_url
        cmd = [ccb_launcher, "-p", message, "--output-format", "json",
               "--dangerously-skip-permissions"]
        if session_id:
            cmd += ["--resume", session_id]
        proc = subprocess.run(cmd, cwd=project_dir, capture_output=True,
                              text=True, timeout=timeout_s, env=env)
        out = proc.stdout.strip()
        obj = None
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    obj = json.loads(line); break
                except Exception:
                    continue
        if obj is None:
            raise RuntimeError((proc.stderr or out or "CCB returned no output")[:500])
        return (obj.get("result") or "(no text reply)"), obj.get("session_id", session_id)

    def run_job(job_id, agent, message, session_id, profile):
        import time
        t0 = time.time()
        try:
            if agent == "ccb":
                reply, sid = run_ccb(message, session_id, profile)
            else:
                reply, sid = run_opencode(message, session_id)
            with jobs_lock:
                jobs[job_id] = {"status": "done", "reply": reply, "session_id": sid,
                                "agent": agent, "profile": profile,
                                "elapsed_s": round(time.time() - t0, 1)}
        except Exception as e:
            with jobs_lock:
                jobs[job_id] = {"status": "error", "error": str(e)[:800],
                                "agent": agent, "elapsed_s": round(time.time() - t0, 1)}

    @app.route("/api/chat", methods=["POST"])
    def api_chat():
        data = request.get_json(force=True, silent=True) or {}
        message = (data.get("message") or "").strip()
        agent = data.get("agent", "opencode")
        profile = data.get("profile") or default_profile
        session_id = data.get("session_id") or None
        if not message:
            return jsonify({"error": "empty message"}), 400
        if agent not in ("opencode", "ccb"):
            return jsonify({"error": "unknown agent"}), 400
        if profile not in PROFILE_TAG:
            return jsonify({"error": "unknown profile"}), 400
        job_id = uuid.uuid4().hex
        with jobs_lock:
            jobs[job_id] = {"status": "running", "agent": agent}
        threading.Thread(target=run_job, args=(job_id, agent, message, session_id, profile),
                         daemon=True).start()
        return jsonify({"job_id": job_id})

    @app.route("/api/chat/poll")
    def api_chat_poll():
        job_id = request.args.get("job_id", "")
        with jobs_lock:
            job = jobs.get(job_id)
        if not job:
            return jsonify({"status": "unknown"}), 404
        if job.get("status") in ("done", "error"):
            with jobs_lock:
                jobs.pop(job_id, None)
        return jsonify(job)

    @app.route("/api/chat/agents")
    def api_chat_agents():
        opencode_up = False
        try:
            urllib.request.urlopen(opencode_base + "/session", timeout=3)
            opencode_up = True
        except Exception as e:
            opencode_up = any(k in str(e) for k in ("session", "405", "400"))
        return jsonify({"opencode": opencode_up, "ccb": os.path.exists(ccb_launcher)})

    @app.route("/api/chat/models")
    def api_chat_models():
        # Which qwable sizes are actually pulled into the ollama endpoint right now?
        present = set()
        try:
            req = urllib.request.Request(qwable_url.rstrip("/") + "/models")
            with urllib.request.urlopen(req, timeout=4) as r:
                present = {m.get("id") for m in (json.loads(r.read().decode()).get("data") or [])}
        except Exception:
            present = set()
        models = [{"profile": "deepseek", "label": "DeepSeek v4 pro", "size": "cloud",
                   "available": os.path.exists(ccb_launcher)}]
        for prof, label, size in (
            ("qwable-large",  "Qwable 大 · 35B Q8", "large"),
            ("qwable-medium", "Qwable 中 · 35B Q4", "medium"),
            ("qwable-small",  "Qwable 小 · 27B Q4", "small"),
        ):
            models.append({"profile": prof, "label": label, "size": size,
                           "available": PROFILE_TAG[prof] in present})
        return jsonify({"models": models, "default": default_profile})

    return app
