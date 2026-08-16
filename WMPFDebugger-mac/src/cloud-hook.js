// JS 层云函数捕获（路线 A）
// 通过 CDP Runtime.evaluate 向小程序 JS 上下文注入 hook，包装
// wx.cloud.callFunction / wx.cloud.Cloud.prototype.callFunction / callContainer。
// 先监听 AddJsContext 拿到 appservice 上下文，再用 ConnectJsContext 切换后注入；
// 捕获结果写入全局数组 __wxCloudHooks，由服务器周期性 evaluate "drain" 取回。
const codex = require("./third-party/RemoteDebugCodex.js");
const messageProto = require("./third-party/WARemoteDebugProtobuf.js");

const HOOK_SCRIPT = `(function () {
  var queue = globalThis.__wxCloudHooks;
  if (!Array.isArray(queue)) queue = globalThis.__wxCloudHooks = [];
  var push = function (item) {
    queue.push(item);
    if (queue.length > 500) queue.splice(0, queue.length - 500);
  };
  var safe = function (v) {
    try { return JSON.stringify(v); } catch (e) { return String(v); }
  };
  var emit = function (phase, name, extra) {
    try { push(Object.assign({ phase: phase, name: name || "" }, extra || {})); } catch (e) {}
  };
  var hookOne = function (obj, method, tag) {
    if (!obj || !obj[method] || obj[method].__wxCloudHooked) return 0;
    var orig = obj[method];
    obj[method] = function (opts) {
      var name = opts && opts.name;
      emit("request", name, { tag: tag, data: safe(opts && opts.data), config: safe(opts && opts.config) });
      try {
        var ret = orig.apply(this, arguments);
        if (ret && typeof ret.then === "function") {
          ret.then(function (res) {
            emit("success", name, { tag: tag, result: safe(res) });
          }, function (err) {
            emit("fail", name, { tag: tag, error: (err && err.errMsg) || String(err) });
          });
        }
        return ret;
      } catch (e) {
        emit("throw", name, { tag: tag, error: String(e) });
        throw e;
      }
    };
    obj[method].__wxCloudHooked = true;
    return 1;
  };
  if (typeof wx === "undefined") return -1;
  if (!wx.cloud) return 0;
  var n = 0;
  n += hookOne(wx.cloud, "callFunction", "wx.cloud.callFunction");
  if (wx.cloud.Cloud && wx.cloud.Cloud.prototype) {
    n += hookOne(wx.cloud.Cloud.prototype, "callFunction", "Cloud.callFunction");
    n += hookOne(wx.cloud.Cloud.prototype, "callContainer", "Cloud.callContainer");
  }
  return n;
})()`;

const DRAIN_SCRIPT = `(function () {
  var q = globalThis.__wxCloudHooks;
  if (!Array.isArray(q) || !q.length) return "";
  globalThis.__wxCloudHooks = [];
  return JSON.stringify(q);
})()`;

let seq = 9000;
const pending = new Map(); // cdp id -> { kind, ctx }
const jsContexts = new Map(); // jscontext_id -> name
const silenced = new Set(); // 失败信息每个 ctx 只打印一次
let injectTimer = null;

const wrapCategory = (rawPayload, category) => {
  const wrappedData = codex.wrapDebugMessageData(rawPayload, category, 0);
  return {
    seq: ++seq,
    category,
    data: wrappedData.buffer,
    compressAlgo: 0,
    originalSize: wrappedData.originalSize,
  };
};

const sendToApplet = (ws, msg) => {
  try {
    const encoded = messageProto.mmbizwxadevremote.WARemoteDebug_DebugMessage.encode(msg).finish();
    if (ws && ws.readyState === 1) ws.send(encoded, { binary: true });
  } catch (e) {
    console.error("[cloud-hook] send error:", e);
  }
};

const connectContext = (ws, ctxId) => {
  sendToApplet(ws, wrapCategory({ jscontext_id: ctxId }, "connectJsContext"));
};

const evaluate = (ws, expression, jsContextId, kind, ctxLabel) => {
  const id = ++seq;
  pending.set(id, { kind, ctx: ctxLabel });
  const params = { expression, returnByValue: true };
  const rawPayload = { jscontext_id: jsContextId || "", op_id: id, payload: JSON.stringify({ id, method: "Runtime.evaluate", params }) };
  const wrappedData = codex.wrapDebugMessageData(rawPayload, "chromeDevtools", 0);
  const msg = {
    seq: id,
    category: "chromeDevtools",
    data: wrappedData.buffer,
    compressAlgo: 0,
    originalSize: wrappedData.originalSize,
  };
  sendToApplet(ws, msg);
};

const run = (ws) => {
  evaluate(ws, HOOK_SCRIPT, "", "inject", "default");
  evaluate(ws, DRAIN_SCRIPT, "", "drain", "default");
  for (const ctxId of jsContexts.keys()) {
    connectContext(ws, ctxId);
    evaluate(ws, HOOK_SCRIPT, ctxId, "inject", "ctx" + ctxId);
    evaluate(ws, DRAIN_SCRIPT, ctxId, "drain", "ctx" + ctxId);
  }
};

const start = (ws) => {
  run(ws);
  if (injectTimer) clearInterval(injectTimer);
  injectTimer = setInterval(() => run(ws), 2500);
};

const stop = () => {
  if (injectTimer) {
    clearInterval(injectTimer);
    injectTimer = null;
  }
  pending.clear();
  jsContexts.clear();
  silenced.clear();
};

const handleIncoming = (unwrappedData) => {
  const lines = [];
  if (!unwrappedData) return lines;

  if (unwrappedData.category === "addJsContext") {
    const id = unwrappedData.data.jscontext_id;
    const name = unwrappedData.data.jscontext_name || "";
    jsContexts.set(id, name);
    lines.push(`[cloud-hook] jscontext id=${id} name=${JSON.stringify(name)}`);
    return lines;
  }
  if (unwrappedData.category === "removeJsContext") {
    jsContexts.delete(unwrappedData.data.jscontext_id);
    return lines;
  }
  if (unwrappedData.category !== "chromeDevtoolsResult") return lines;

  let msg = null;
  try {
    msg = JSON.parse(unwrappedData.data.payload);
  } catch (e) {
    return lines;
  }
  if (msg.method === "Runtime.executionContextCreated") {
    const ctx = msg.params && msg.params.context;
    if (ctx && ctx.id && process.env.DEBUG_CLOUD_HOOK) {
      lines.push(`[dbg] executionContextCreated id=${ctx.id} aux=${JSON.stringify(ctx.auxData || {})}`);
    }
    return lines;
  }
  if (msg.id && pending.has(msg.id)) {
    const { kind, ctx } = pending.get(msg.id);
    pending.delete(msg.id);
    const val = msg.result && msg.result.result ? msg.result.result.value : undefined;
    if (kind === "inject") {
      if (val === 1) lines.push(`[cloud-hook] 注入成功(${ctx})：wx.cloud 已 hook`);
      else if (val === 0) {
        if (!silenced.has(ctx + ":0")) { silenced.add(ctx + ":0"); lines.push(`[cloud-hook] (${ctx}) 有 wx 但无 wx.cloud`); }
      } else if (val === -1) {
        if (!silenced.has(ctx + ":-1")) { silenced.add(ctx + ":-1"); lines.push(`[cloud-hook] (${ctx}) 无 wx，跳过`); }
      }
    } else if (kind === "drain" && typeof val === "string" && val) {
      try {
        const items = JSON.parse(val);
        for (const it of items) {
          const tag = it.tag || "wx.cloud.callFunction";
          const name = it.name ? " name=" + it.name : "";
          const extra =
            it.data !== undefined ? " data=" + it.data :
            it.result !== undefined ? " result=" + it.result :
            it.error !== undefined ? " error=" + it.error : "";
          lines.push(`[cloud] ${it.phase} ${tag}${name}${extra}`);
        }
      } catch (e) {
        lines.push("[cloud] drain 解析失败: " + val.slice(0, 200));
      }
    }
  }
  return lines;
};

module.exports = { start, stop, handleIncoming };
