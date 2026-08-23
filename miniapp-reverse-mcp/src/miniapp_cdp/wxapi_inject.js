(function () {
  if (window.__wxApiAudit && window.__wxApiAudit.__version === 3) return;
  if (window.__wxApiAudit) {
    try { window.__wxApiAudit.uninstall(); } catch (e) {}
  }

  var calls = [];
  var MAX_CALLS = 1000;
  var installed = false;
  var frameHooks = [];

  function safeClone(value) {
    try { return JSON.parse(JSON.stringify(value)); } catch (e) { return String(value); }
  }

  function record(type, name, data, result, status, error) {
    var item = {
      type: type,
      name: name,
      data: data,
      timestamp: new Date().toLocaleTimeString(),
      ts: Date.now(),
      status: status || 'pending'
    };
    if (result !== undefined) item.result = result;
    if (error !== undefined) item.error = error;
    calls.push(item);
    if (calls.length > MAX_CALLS) calls.splice(0, calls.length - MAX_CALLS);
  }

  function collectFrames() {
    var frames = [];
    var seen = [];
    function tryAdd(w) {
      try {
        if (!w || seen.indexOf(w) !== -1) return;
        seen.push(w);
        if (w.wx) frames.push(w);
      } catch (e) {}
    }
    tryAdd(window);
    var sources = [window];
    try { if (window.parent && window.parent !== window) sources.push(window.parent); } catch (e) {}
    for (var s = 0; s < sources.length; s++) {
      try {
        var src = sources[s];
        if (src.frames) {
          for (var i = 0; i < src.frames.length; i++) {
            tryAdd(src.frames[i]);
          }
        }
      } catch (e) {}
    }
    return frames;
  }

  function wrapFrame(frame, name, type, originals) {
    if (!frame.wx || !frame.wx[name] || typeof frame.wx[name] !== 'function' || originals[name]) return false;
    var original = frame.wx[name].bind(frame.wx);
    originals[name] = original;

    function wrapper(options) {
      options = options || {};
      var callData = safeClone(options);
      delete callData.success;
      delete callData.fail;
      delete callData.complete;

      var recorded = false;
      var hasCallback = !!(options.success || options.fail);
      var originalSuccess = options.success;
      var originalFail = options.fail;

      options.success = function (res) {
        if (!recorded) {
          recorded = true;
          record(type, name, callData, safeClone(res), 'success');
        }
        if (originalSuccess) originalSuccess(res);
      };
      options.fail = function (err) {
        if (!recorded) {
          recorded = true;
          record(type, name, callData, null, 'fail', err && err.errMsg ? err.errMsg : String(err));
        }
        if (originalFail) originalFail(err);
      };

      var ret;
      try { ret = original(options); } catch (e) {
        if (!recorded) {
          recorded = true;
          record(type, name, callData, null, 'throw', String(e));
        }
        throw e;
      }

      if (!hasCallback && ret && typeof ret.then === 'function') {
        ret.then(function (res) {
          if (!recorded) {
            recorded = true;
            record(type, name, callData, safeClone(res), 'success');
          }
        }, function (err) {
          if (!recorded) {
            recorded = true;
            record(type, name, callData, null, 'fail', err && err.errMsg ? err.errMsg : String(err));
          }
        });
      }
      return ret;
    }

    try {
      Object.defineProperty(frame.wx, name, {
        configurable: true,
        enumerable: true,
        writable: true,
        value: wrapper
      });
    } catch (e) {
      frame.wx[name] = wrapper;
    }
    return true;
  }

  var mapping = {
    auth: ['login', 'getUserProfile', 'getUserInfo', 'checkSession'],
    request: ['request', 'uploadFile', 'downloadFile'],
    storage: ['setStorage', 'getStorage', 'removeStorage', 'clearStorage', 'getStorageInfo'],
    share: ['showShareMenu', 'shareAppMessage', 'updateShareMenu'],
    location: ['getLocation', 'chooseLocation', 'openLocation'],
    device: ['getSystemInfo', 'getNetworkType', 'scanCode', 'vibrateShort'],
    nav: ['navigateTo', 'redirectTo', 'reLaunch', 'switchTab', 'navigateBack'],
    media: ['chooseImage', 'previewImage', 'chooseVideo'],
    clipboard: ['setClipboardData', 'getClipboardData'],
    pay: ['requestPayment']
  };

  window.__wxApiAudit = {
    __version: 3,
    install: function () {
      if (installed) return { ok: true, already: true };
      var frames = collectFrames();
      if (frames.length === 0) return { ok: false, reason: 'wx not available' };

      var hooked = [];
      for (var i = 0; i < frames.length; i++) {
        var frame = frames[i];
        var originals = {};
        for (var type in mapping) {
          var methods = mapping[type];
          for (var j = 0; j < methods.length; j++) {
            var method = methods[j];
            if (wrapFrame(frame, method, type, originals)) hooked.push(method);
          }
        }
        frameHooks.push({ frame: frame, originals: originals });
      }
      installed = hooked.length > 0;
      return { ok: installed, hooked: hooked, frames: frames.length };
    },

    uninstall: function () {
      for (var i = 0; i < frameHooks.length; i++) {
        var entry = frameHooks[i];
        try {
          for (var name in entry.originals) {
            try {
              Object.defineProperty(entry.frame.wx, name, {
                configurable: true,
                enumerable: true,
                writable: true,
                value: entry.originals[name]
              });
            } catch (e) {
              entry.frame.wx[name] = entry.originals[name];
            }
          }
        } catch (e) {}
      }
      frameHooks = [];
      installed = false;
    },

    getCalls: function () {
      return calls.slice();
    },

    clear: function () {
      calls = [];
    },

    replay: function (name, data) {
      var original = null;
      for (var i = 0; i < frameHooks.length; i++) {
        if (frameHooks[i].originals[name]) {
          original = frameHooks[i].originals[name];
          break;
        }
      }
      if (!original) return Promise.resolve({ ok: false, reason: 'api not hooked: ' + name });

      return new Promise(function (resolve) {
        var opts = safeClone(data || {});
        var timer = setTimeout(function () {
          resolve({ ok: true, status: 'timeout', error: 'replay timeout' });
        }, 10000);
        opts.success = function (res) {
          clearTimeout(timer);
          resolve({ ok: true, status: 'success', result: safeClone(res) });
        };
        opts.fail = function (err) {
          clearTimeout(timer);
          resolve({ ok: true, status: 'fail', error: err && err.errMsg ? err.errMsg : String(err) });
        };
        try {
          var ret = original(opts);
          if (ret && typeof ret.then === 'function') {
            ret.then(function (res) {
              clearTimeout(timer);
              resolve({ ok: true, status: 'success', result: safeClone(res) });
            }, function (err) {
              clearTimeout(timer);
              resolve({ ok: true, status: 'fail', error: err && err.errMsg ? err.errMsg : String(err) });
            });
          }
        } catch (e) {
          clearTimeout(timer);
          resolve({ ok: false, status: 'throw', error: String(e) });
        }
      });
    }
  };
})();
