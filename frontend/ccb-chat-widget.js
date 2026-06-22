/*
 * ccb-chat-widget.js — self-injecting "talk to the agent" panel for the viz page.
 *
 * Install: add ONE line before </body> in your index.html:
 *     <script src="/ccb-chat-widget.js"></script>
 * (serve this file as a static asset; it needs the /api/chat backend from ccb_chat.py)
 *
 * It creates a collapsible left panel with a toggle between the original
 * opencode agent and the CCB agent (Claude Code Best). Both run on DeepSeek
 * v4 pro, keep independent sessions, and can run skills from the browser.
 * Uses the async job API (POST /api/chat -> poll /api/chat/poll) so a slow
 * skill turn never blocks the page.
 */
(function () {
  if (window.__ccbChatLoaded) return;
  window.__ccbChatLoaded = true;

  var CSS = [
    "#chat-toggle{position:fixed;left:0;top:50%;transform:translateY(-50%);z-index:1001;background:#1f6feb;color:#fff;border:none;padding:14px 7px;border-radius:0 8px 8px 0;cursor:pointer;writing-mode:vertical-rl;font-size:.8rem;font-weight:600;letter-spacing:1px;box-shadow:2px 0 10px rgba(0,0,0,.4)}",
    "#chat-toggle:hover{background:#388bfd}",
    "#chat-panel{position:fixed;left:0;top:0;bottom:0;width:410px;max-width:92vw;background:#161b22;color:#e6edf3;border-right:1px solid #30363d;display:flex;flex-direction:column;z-index:1000;transform:translateX(-100%);transition:transform .2s ease;box-shadow:2px 0 20px rgba(0,0,0,.5);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}",
    "#chat-panel.open{transform:translateX(0)}",
    ".chat-head{padding:12px 14px;border-bottom:1px solid #30363d}",
    ".chat-title{font-size:1rem;font-weight:600;display:flex;justify-content:space-between;align-items:center}",
    ".chat-close{background:none;border:none;color:#8b949e;cursor:pointer;font-size:1.4rem;line-height:1}",
    ".chat-agent-toggle{display:flex;gap:6px;margin-top:10px}",
    ".chat-agent-btn{flex:1;padding:7px 4px;border:1px solid #30363d;background:#0d1117;color:#8b949e;border-radius:6px;cursor:pointer;font-size:.78rem;font-weight:500}",
    ".chat-agent-btn.active{background:#1f6feb;color:#fff;border-color:#1f6feb}",
    ".chat-hint{font-size:.72rem;color:#6e7681;margin-top:6px}",
    ".chat-msgs{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px}",
    ".chat-msg{padding:9px 12px;border-radius:8px;font-size:.85rem;white-space:pre-wrap;word-break:break-word;line-height:1.5}",
    ".chat-msg.user{background:#1f6feb;color:#fff;align-self:flex-end;max-width:88%}",
    ".chat-msg.agent{background:#21262d;color:#e6edf3;align-self:flex-start;max-width:96%}",
    ".chat-msg.system{background:transparent;color:#8b949e;font-style:italic;font-size:.76rem;align-self:center;text-align:center}",
    ".chat-input-row{padding:12px;border-top:1px solid #30363d;display:flex;gap:8px}",
    "#chat-input{flex:1;resize:none;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:8px;font-family:inherit;font-size:.85rem}",
    "#chat-send{background:#238636;color:#fff;border:none;border-radius:6px;padding:0 16px;cursor:pointer;font-weight:600;font-size:.85rem}",
    "#chat-send:disabled{opacity:.5;cursor:default}",
    ".chat-model-row{display:none;margin-top:8px;align-items:center;gap:6px}",
    ".chat-model-row.show{display:flex}",
    ".chat-model-row label{font-size:.72rem;color:#8b949e;white-space:nowrap}",
    "#chat-model{flex:1;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:5px;font-size:.76rem}"
  ].join("\n");

  var HTML =
    '<button id="chat-toggle">💬 AGENT</button>' +
    '<div id="chat-panel">' +
    '  <div class="chat-head">' +
    '    <div class="chat-title"><span>🤖 Agent Chat</span><button class="chat-close" id="chat-close-btn" title="collapse">×</button></div>' +
    '    <div class="chat-agent-toggle">' +
    '      <button class="chat-agent-btn active" id="agent-btn-opencode">Original · opencode</button>' +
    '      <button class="chat-agent-btn" id="agent-btn-ccb">Claude Code Best</button>' +
    '    </div>' +
    '    <div class="chat-model-row" id="chat-model-row">' +
    '      <label>Model</label>' +
    '      <select id="chat-model"></select>' +
    '    </div>' +
    '    <div class="chat-hint">opencode runs DeepSeek · CCB can switch DeepSeek / Qwable 大中小 · independent sessions</div>' +
    '  </div>' +
    '  <div class="chat-msgs" id="chat-msgs"></div>' +
    '  <div class="chat-input-row">' +
    '    <textarea id="chat-input" rows="2" placeholder="Send the agent an instruction…  (Enter to send, Shift+Enter for newline)"></textarea>' +
    '    <button id="chat-send">Send</button>' +
    '  </div>' +
    '</div>';

  function init() {
    var style = document.createElement("style");
    style.textContent = CSS;
    document.head.appendChild(style);
    var wrap = document.createElement("div");
    wrap.innerHTML = HTML;
    while (wrap.firstChild) document.body.appendChild(wrap.firstChild);

    var agent = "opencode";
    var profile = "deepseek";              // CCB model profile (deepseek | qwable-large/medium/small)
    var profileLabels = {};
    var sessions = { opencode: null, ccb: null };
    var busy = false;
    var $ = function (id) { return document.getElementById(id); };

    function toggleChat() { $("chat-panel").classList.toggle("open"); }
    function addMsg(role, text) {
      var box = $("chat-msgs");
      var d = document.createElement("div");
      d.className = "chat-msg " + role;
      d.textContent = text;
      box.appendChild(d); box.scrollTop = box.scrollHeight;
      return d;
    }
    function selectAgent(a) {
      if (busy) return;
      agent = a;
      $("agent-btn-opencode").classList.toggle("active", a === "opencode");
      $("agent-btn-ccb").classList.toggle("active", a === "ccb");
      $("chat-model-row").classList.toggle("show", a === "ccb");   // model picker only for CCB
      addMsg("system", "Switched to " + (a === "ccb" ? "Claude Code Best (CCB)" : "Original (opencode)") + " · independent session");
    }
    function loadModels() {
      fetch("/api/chat/models").then(function (r) { return r.json(); }).then(function (d) {
        var sel = $("chat-model"); sel.innerHTML = "";
        (d.models || []).forEach(function (m) {
          var o = document.createElement("option");
          o.value = m.profile;
          o.textContent = m.label + (m.available ? "" : " (not installed)");
          o.disabled = !m.available;
          profileLabels[m.profile] = m.label;
          sel.appendChild(o);
        });
        var models = d.models || [];
        var avail = models.filter(function (m) { return m.available; });
        profile = d.default || "deepseek";
        if (!avail.some(function (m) { return m.profile === profile; }) && avail.length) profile = avail[0].profile;
        sel.value = profile;
      }).catch(function () {});
    }
    async function sendChat() {
      if (busy) return;
      var inp = $("chat-input");
      var msg = inp.value.trim();
      if (!msg) return;
      inp.value = ""; addMsg("user", msg);
      busy = true; $("chat-send").disabled = true;
      var label = agent === "ccb" ? ("CCB·" + (profileLabels[profile] || profile)) : "opencode";
      var status = addMsg("system", label + " thinking…");
      var t0 = Date.now();
      try {
        var r = await fetch("/api/chat", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ message: msg, agent: agent, profile: profile, session_id: sessions[agent] })
        });
        var start = await r.json();
        if (!start.job_id) throw new Error(start.error || "no job id");
        var result;
        while (true) {
          await new Promise(function (res) { setTimeout(res, 1500); });
          status.textContent = label + " running… " + Math.round((Date.now() - t0) / 1000) + "s";
          var pr = await fetch("/api/chat/poll?job_id=" + start.job_id);
          var j = await pr.json();
          if (j.status === "done" || j.status === "error") { result = j; break; }
          if (j.status === "unknown") { result = { status: "error", error: "job lost (server restart?)" }; break; }
        }
        status.remove();
        if (result.status === "done") {
          sessions[agent] = result.session_id || sessions[agent];
          addMsg("agent", result.reply || "(empty reply)");
          addMsg("system", "✓ " + label + " · " + (result.elapsed_s || "?") + "s");
        } else {
          addMsg("system", "❌ " + label + " error: " + (result.error || "unknown"));
        }
      } catch (e) {
        status.remove();
        addMsg("system", "❌ request failed: " + e);
      } finally {
        busy = false; $("chat-send").disabled = false; inp.focus();
      }
    }

    $("chat-toggle").addEventListener("click", toggleChat);
    $("chat-close-btn").addEventListener("click", toggleChat);
    $("agent-btn-opencode").addEventListener("click", function () { selectAgent("opencode"); });
    $("agent-btn-ccb").addEventListener("click", function () { selectAgent("ccb"); });
    $("chat-send").addEventListener("click", sendChat);
    $("chat-model").addEventListener("change", function () {
      profile = this.value;
      addMsg("system", "CCB model → " + (profileLabels[profile] || profile));
    });
    $("chat-input").addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendChat(); }
    });
    addMsg("system", "Pick an agent above and type an instruction. e.g. \"open a sample brain in NiiVue\" or \"segment sub941's T1\".");
    // Tell the backend which agents are reachable, and load the CCB model list.
    fetch("/api/chat/agents").then(function (r) { return r.json(); }).then(function (a) {
      if (!a.ccb) $("agent-btn-ccb").title = "CCB launcher not found — see install README";
    }).catch(function () {});
    loadModels();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else { init(); }
})();
