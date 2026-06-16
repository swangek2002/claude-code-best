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
    ccb_launcher = ccb_launcher or os.environ.get(
        "CCB_LAUNCHER", os.path.join(project_dir, "scripts", "ccb-deepseek.sh"))
    opencode_base = opencode_base or os.environ.get(
        "OPENCODE_BASE", "http://127.0.0.1:4097")
    opencode_model = opencode_model or {
        "providerID": os.environ.get("OPENCODE_MODEL_PROVIDER", "deepseek"),
        "modelID": os.environ.get("OPENCODE_MODEL_ID", "deepseek-v4-pro"),
    }
    timeout_s = timeout_s or int(os.environ.get("CHAT_TIMEOUT_S", "900"))

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

    def run_ccb(message, session_id):
        cmd = [ccb_launcher, "-p", message, "--output-format", "json",
               "--dangerously-skip-permissions"]
        if session_id:
            cmd += ["--resume", session_id]
        proc = subprocess.run(cmd, cwd=project_dir, capture_output=True,
                              text=True, timeout=timeout_s)
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

    def run_job(job_id, agent, message, session_id):
        import time
        t0 = time.time()
        try:
            reply, sid = (run_ccb if agent == "ccb" else run_opencode)(message, session_id)
            with jobs_lock:
                jobs[job_id] = {"status": "done", "reply": reply, "session_id": sid,
                                "agent": agent, "elapsed_s": round(time.time() - t0, 1)}
        except Exception as e:
            with jobs_lock:
                jobs[job_id] = {"status": "error", "error": str(e)[:800],
                                "agent": agent, "elapsed_s": round(time.time() - t0, 1)}

    @app.route("/api/chat", methods=["POST"])
    def api_chat():
        data = request.get_json(force=True, silent=True) or {}
        message = (data.get("message") or "").strip()
        agent = data.get("agent", "opencode")
        session_id = data.get("session_id") or None
        if not message:
            return jsonify({"error": "empty message"}), 400
        if agent not in ("opencode", "ccb"):
            return jsonify({"error": "unknown agent"}), 400
        job_id = uuid.uuid4().hex
        with jobs_lock:
            jobs[job_id] = {"status": "running", "agent": agent}
        threading.Thread(target=run_job, args=(job_id, agent, message, session_id),
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

    return app
