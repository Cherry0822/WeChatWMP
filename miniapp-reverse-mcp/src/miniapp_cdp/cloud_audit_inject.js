(function() {
  if (window._cloudAuditInjected) return;
  window._cloudAuditInjected = true;

  var cloudAudit = {
    hookedCalls: [],
    _hooked: false,
    _hookedClouds: [],   // [{cloud, appId, origMethods}]
    _autoHookTimer: null,
    autoHookEnabled: false,

    // ── 扫描所有 frame，收集所有 wx.cloud 实例 ──
    _findAllFrames: function() {
      var frames = [];
      var seen = [];
      function tryAdd(w) {
        try {
          if (!w || !w.wx || !w.__wxConfig) return;
          for (var i = 0; i < seen.length; i++) { if (seen[i] === w) return; }
          seen.push(w);
          frames.push(w);
        } catch(e) {}
      }
      tryAdd(window);
      var sources = [window];
      try { if (window.parent && window.parent !== window) sources.push(window.parent); } catch(e) {}
      for (var s = 0; s < sources.length; s++) {
        try {
          var src = sources[s];
          if (src.frames) {
            for (var i = 0; i < src.frames.length; i++) {
              try { tryAdd(src.frames[i]); } catch(e) {}
            }
          }
        } catch(e) {}
      }
      return frames;
    },

    _getAppIdFromFrame: function(frame) {
      try {
        var cfg = frame.__wxConfig || {};
        if (cfg.accountInfo && cfg.accountInfo.appId) return cfg.accountInfo.appId;
        if (cfg.appId) return cfg.appId;
      } catch(e) {}
      return '';
    },

    _getEnvFromFrame: function(frame) {
      try {
        var cfg = frame.__wxConfig || {};
        if (cfg.envList) return cfg.envList;
        if (cfg.cloud && cfg.cloud.env) return cfg.cloud.env;
        if (frame.wx.cloud && frame.wx.cloud._config) return frame.wx.cloud._config.env;
      } catch(e) {}
      return null;
    },

    // ── 环境探测 (返回所有发现的小程序) ──
    detectEnv: function() {
      var frames = this._findAllFrames();
      if (frames.length === 0) {
        return { ok: false, reason: 'no miniprogram frames found' };
      }
      var apps = [];
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        try {
          if (!f.wx || !f.wx.cloud) continue;
          apps.push({
            appId: this._getAppIdFromFrame(f),
            env: this._getEnvFromFrame(f),
            inited: !!(f.wx.cloud._config || f.wx.cloud.inited)
          });
        } catch(e) {}
      }
      return {
        ok: apps.length > 0,
        reason: apps.length === 0 ? 'wx.cloud not available' : undefined,
        hasCloud: apps.length > 0,
        apps: apps,
        // 兼容旧接口
        appId: apps.length > 0 ? apps[0].appId : '',
        env: apps.length > 0 ? apps[0].env : null,
        inited: apps.length > 0 ? apps[0].inited : false
      };
    },

    // ── 通用工具 ──
    _safeClone: function(obj) {
      try { return JSON.parse(JSON.stringify(obj)); } catch(e) { return String(obj); }
    },

    _record: function(type, name, appId, data, result, status, error) {
      var r = {
        type: type, name: name, appId: appId,
        data: data, timestamp: new Date().toLocaleTimeString(),
        ts: Date.now(), status: status || 'pending'
      };
      if (result !== undefined) r.result = result;
      if (error !== undefined) r.error = error;
      this.hookedCalls.push(r);
    },

    // ── 通用 hook 包装器 ──
    _wrapMethod: function(cloud, method, type, nameExtract, appId, origStore) {
      var orig = cloud[method];
      if (!orig || typeof orig !== 'function') return false;
      origStore[method] = orig.bind(cloud);
      var self = this;
      cloud[method] = function(options) {
        options = options || {};
        var callName = nameExtract ? nameExtract(options) : method;
        var callData = self._safeClone(options);
        delete callData.success; delete callData.fail; delete callData.complete;
        delete callData.filePath; delete callData.tempFilePath;

        var recorded = false;
        var hasCb = !!(options.success || options.fail);
        var origSuccess = options.success;
        var origFail = options.fail;

        options.success = function(res) {
          if (!recorded) { recorded = true; self._record(type, callName, appId, callData, self._safeClone(res), 'success'); }
          if (origSuccess) origSuccess(res);
        };
        options.fail = function(err) {
          if (!recorded) { recorded = true; self._record(type, callName, appId, callData, null, 'fail', err ? (err.errMsg || JSON.stringify(err)) : 'unknown'); }
          if (origFail) origFail(err);
        };

        var ret = origStore[method](options);
        if (!hasCb && ret && typeof ret.then === 'function') {
          ret.then(function(res) {
            if (!recorded) { recorded = true; self._record(type, callName, appId, callData, self._safeClone(res), 'success'); }
          })['catch'](function(err) {
            if (!recorded) { recorded = true; self._record(type, callName, appId, callData, null, 'fail', err ? (err.errMsg || JSON.stringify(err)) : 'unknown'); }
          });
        }
        return ret;
      };
      return true;
    },

    // ── Hook 数据库 ──
    _hookDatabase: function(cloud, appId, origStore) {
      var origDb = cloud.database;
      if (!origDb) return;
      origStore['database'] = origDb.bind(cloud);
      var self = this;

      cloud.database = function(opts) {
        var db = origStore['database'](opts);
        if (!db) return db;
        self._proxyDbCollection(db, appId);
        return db;
      };
    },

    _proxyDbCollection: function(db, appId) {
      var origCol = db.collection;
      if (!origCol) return;
      var self = this;

      db.collection = function(collName) {
        var col = origCol.call(db, collName);
        if (!col) return col;

        // Hook 终端操作
        ['add', 'get', 'update', 'remove', 'count'].forEach(function(m) {
          if (col[m]) self._wrapTerminal(col, m, 'db.' + m, collName, appId);
        });

        // Hook doc()
        if (col.doc) {
          var origDoc = col.doc.bind(col);
          col.doc = function(docId) {
            var ref = origDoc(docId);
            if (!ref) return ref;
            ['get', 'update', 'set', 'remove'].forEach(function(m) {
              if (ref[m]) self._wrapTerminal(ref, m, 'db.doc.' + m, collName + '/' + docId, appId);
            });
            return ref;
          };
        }

        // Hook where()
        if (col.where) {
          var origWhere = col.where.bind(col);
          col.where = function(cond) {
            var q = origWhere(cond);
            if (!q) return q;
            ['get', 'update', 'remove', 'count'].forEach(function(m) {
              if (q[m]) self._wrapTerminal(q, m, 'db.where.' + m, collName, appId, { where: self._safeClone(cond) });
            });
            return q;
          };
        }

        // Hook aggregate()
        if (col.aggregate) {
          var origAgg = col.aggregate.bind(col);
          col.aggregate = function() {
            var agg = origAgg();
            if (!agg || !agg.end) return agg;
            self._wrapTerminal(agg, 'end', 'db.aggregate', collName, appId);
            return agg;
          };
        }

        return col;
      };
    },

    // 包装一个终端方法（支持 callback + promise）
    _wrapTerminal: function(obj, method, type, name, appId, extraData) {
      var orig = obj[method].bind(obj);
      var self = this;
      obj[method] = function(opts) {
        opts = opts || {};
        var callData = extraData ? self._safeClone(extraData) : {};
        if (opts.data) callData.data = self._safeClone(opts.data);

        var recorded = false;
        var hasCb = !!(opts.success || opts.fail);
        var origSuccess = opts.success;
        var origFail = opts.fail;

        opts.success = function(res) {
          if (!recorded) { recorded = true; self._record(type, name, appId, callData, self._safeClone(res), 'success'); }
          if (origSuccess) origSuccess(res);
        };
        opts.fail = function(err) {
          if (!recorded) { recorded = true; self._record(type, name, appId, callData, null, 'fail', err ? (err.errMsg || JSON.stringify(err)) : 'unknown'); }
          if (origFail) origFail(err);
        };

        var ret = orig(opts);
        if (!hasCb && ret && typeof ret.then === 'function') {
          ret.then(function(res) {
            if (!recorded) { recorded = true; self._record(type, name, appId, callData, self._safeClone(res), 'success'); }
          })['catch'](function(err) {
            if (!recorded) { recorded = true; self._record(type, name, appId, callData, null, 'fail', err ? (err.errMsg || JSON.stringify(err)) : 'unknown'); }
          });
        }
        return ret;
      };
    },

    // ── 已知方法的类型和名称提取器 ──
    _knownMethods: {
      'callFunction':     { type: 'function',  ne: function(o) { return o.name || 'unknown'; } },
      'uploadFile':       { type: 'storage',   ne: function(o) { return 'uploadFile: ' + (o.cloudPath || ''); } },
      'downloadFile':     { type: 'storage',   ne: function(o) { return 'downloadFile: ' + (o.fileID || ''); } },
      'deleteFile':       { type: 'storage',   ne: function(o) { return 'deleteFile(' + (o.fileList||[]).length + ')'; } },
      'getTempFileURL':   { type: 'storage',   ne: function(o) { return 'getTempFileURL(' + (o.fileList||[]).length + ')'; } },
      'callContainer':    { type: 'container', ne: function(o) { return o.path || 'callContainer'; } },
      'connectContainer': { type: 'container', ne: function(o) { return 'connectContainer: ' + (o.service || ''); } }
    },
    _skipProps: { 'init':1, 'database':1, 'CloudID':1, 'constructor':1, 'prototype':1, '__proto__':1 },

    // ── 对一个 cloud 实例安装全部 hook ──
    _hookOneCloud: function(cloud, appId) {
      var origStore = {};
      var hookedList = [];

      var wrapKnown = function(k, known) {
        if (hookedList.indexOf(k) !== -1) return false;
        if (this._skipProps[k] || k.charAt(0) === '_') return false;
        try { if (typeof cloud[k] !== 'function') return false; } catch(e) { return false; }
        var type = known ? known.type : 'cloud';
        var ne = known ? known.ne : (function(name) { return function() { return name; }; })(k);
        if (this._wrapMethod(cloud, k, type, ne, appId, origStore)) {
          hookedList.push(k);
          return true;
        }
        return false;
      }.bind(this);

      // 动态枚举所有方法
      var keys = [];
      try { keys = Object.keys(cloud); } catch(e) {}
      try {
        var proto = Object.getPrototypeOf(cloud);
        if (proto) {
          var pk = Object.getOwnPropertyNames(proto);
          for (var i = 0; i < pk.length; i++) { if (keys.indexOf(pk[i]) === -1) keys.push(pk[i]); }
        }
      } catch(e) {}

      for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        var known = this._knownMethods[k];
        wrapKnown(k, known);
      }

      // 显式补齐已知云方法：部分微信版本/小程序里，
      // wx.cloud 方法可能是不可枚举或 Proxy 属性，导致上面枚举不到。
      var knownNames = Object.keys(this._knownMethods);
      for (var j = 0; j < knownNames.length; j++) {
        var k2 = knownNames[j];
        wrapKnown(k2, this._knownMethods[k2]);
      }

      // 数据库特殊处理
      this._hookDatabase(cloud, appId, origStore);

      this._hookedClouds.push({ cloud: cloud, appId: appId, origMethods: origStore });
      return hookedList;
    },

    // ── 自动扫描所有 frame 并 hook ──
    autoHookScan: function() {
      var frames = this._findAllFrames();
      var newApps = [];
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        try {
          if (!f.wx || !f.wx.cloud) continue;
          var cloud = f.wx.cloud;
          // 检查是否已经 hook 过这个 cloud 实例
          var alreadyHooked = false;
          for (var j = 0; j < this._hookedClouds.length; j++) {
            if (this._hookedClouds[j].cloud === cloud) { alreadyHooked = true; break; }
          }
          if (alreadyHooked) continue;

          var appId = this._getAppIdFromFrame(f);
          var methods = this._hookOneCloud(cloud, appId);
          newApps.push({ appId: appId, methods: methods });
        } catch(e) {}
      }
      return newApps;
    },

    // ── 公开 API ──
    installHook: function() {
      var newApps = this.autoHookScan();
      if (this._hookedClouds.length === 0) {
        this._hooked = false;
        return { ok: false, reason: 'wx.cloud not available in any frame' };
      }
      // 启动自动扫描定时器（每 3 秒扫描新 frame）
      this._hooked = true;
      this._startAutoScan();
      return {
        ok: true,
        totalHooked: this._hookedClouds.length,
        newApps: newApps,
        hookedMethods: newApps.length > 0 ? newApps[0].methods : []
      };
    },

    _startAutoScan: function() {
      if (this._autoHookTimer) return;
      this.autoHookEnabled = true;
      var self = this;
      this._autoHookTimer = setInterval(function() {
        if (!self.autoHookEnabled) return;
        self.autoHookScan();
      }, 3000);
    },

    stopAutoHook: function() {
      this.autoHookEnabled = false;
      if (this._autoHookTimer) {
        clearInterval(this._autoHookTimer);
        this._autoHookTimer = null;
      }
    },

    uninstallHook: function() {
      this.stopAutoHook();
      for (var i = 0; i < this._hookedClouds.length; i++) {
        var entry = this._hookedClouds[i];
        try {
          for (var m in entry.origMethods) {
            try { entry.cloud[m] = entry.origMethods[m]; } catch(e) {}
          }
        } catch(e) {}
      }
      this._hookedClouds = [];
      this._hooked = false;
    },

    getHookedCalls: function() { return this.hookedCalls.slice(); },
    clearHookedCalls: function() { this.hookedCalls = []; },

    getHookedApps: function() {
      var apps = [];
      for (var i = 0; i < this._hookedClouds.length; i++) {
        apps.push(this._hookedClouds[i].appId);
      }
      return apps;
    },

    getDiscoveredFunctions: function() {
      var map = {};
      for (var i = 0; i < this.hookedCalls.length; i++) {
        var c = this.hookedCalls[i];
        var key = (c.type || 'function') + ':' + c.appId + ':' + c.name;
        if (!map[key]) {
          map[key] = { name: c.name, type: c.type || 'function', appId: c.appId || '', params: [], count: 0 };
        }
        map[key].count++;
        if (c.data && typeof c.data === 'object') {
          var keys = Object.keys(c.data);
          for (var k = 0; k < keys.length; k++) {
            if (map[key].params.indexOf(keys[k]) === -1) map[key].params.push(keys[k]);
          }
        }
      }
      var result = [];
      for (var k in map) { result.push(map[k]); }
      return result;
    },

    // ── 补充扫描 ──
    scanCloudFunctions: function() {
      var frames = this._findAllFrames();
      var found = {};
      for (var fi = 0; fi < frames.length; fi++) {
        var f = frames[fi];
        var appCodes = [];
        try { if (f.__wxAppCode__) appCodes.push(f.__wxAppCode__); } catch(e) {}
        for (var a = 0; a < appCodes.length; a++) {
          var code = appCodes[a];
          for (var key in code) {
            try {
              var val = code[key];
              var src = typeof val === 'string' ? val :
                        (typeof val === 'function' ? val.toString() : null);
              if (src && src.length > 20) {
                if (src.indexOf('callFunction') !== -1) this._extractCalls(src, found);
                if (src.indexOf('.collection(') !== -1) this._extractDbOps(src, found);
                this._extractFileOps(src, found);
              }
            } catch(e) {}
          }
        }
      }
      var result = [];
      for (var name in found) {
        result.push({ name: name, type: found[name].type, params: found[name].params, count: found[name].count });
      }
      return result;
    },

    _extractCalls: function(src, found) {
      var re = /callFunction\s*\(\s*\{[^}]{0,500}?name\s*:\s*["']([^"']+)["']/g;
      var m;
      while ((m = re.exec(src)) !== null) {
        var key = 'fn:' + m[1];
        if (!found[key]) found[key] = { type: 'function', params: [], count: 0 };
        found[key].count++;
        var after = src.substring(m.index, Math.min(m.index + 600, src.length));
        var dm = after.match(/data\s*:\s*\{([^}]{1,400})\}/);
        if (dm) {
          var fields = dm[1].match(/(\w+)\s*:/g);
          if (fields) {
            for (var i = 0; i < fields.length; i++) {
              var fn = fields[i].replace(/\s*:$/, '');
              if (fn !== 'name' && fn !== 'success' && fn !== 'fail' && fn !== 'complete'
                  && found[key].params.indexOf(fn) === -1) found[key].params.push(fn);
            }
          }
        }
      }
    },

    _extractDbOps: function(src, found) {
      var re = /\.collection\s*\(\s*["']([^"']+)["']\s*\)/g;
      var m;
      while ((m = re.exec(src)) !== null) {
        var key = 'db:' + m[1];
        if (!found[key]) found[key] = { type: 'database', params: [], count: 0 };
        found[key].count++;
        var after = src.substring(m.index, Math.min(m.index + 300, src.length));
        ['add','get','update','remove','count','aggregate','doc','where'].forEach(function(op) {
          if (after.indexOf('.' + op + '(') !== -1 && found[key].params.indexOf(op) === -1)
            found[key].params.push(op);
        });
      }
    },

    _extractFileOps: function(src, found) {
      ['uploadFile','downloadFile','deleteFile','getTempFileURL'].forEach(function(m) {
        if (src.indexOf(m) !== -1) {
          var key = 'storage:' + m;
          if (!found[key]) found[key] = { type: 'storage', params: [], count: 0 };
          found[key].count++;
        }
      });
    },

    // ── 确保云环境已初始化 ──
    ensureCloudInit: function() {
      var frames = this._findAllFrames();
      var initedAny = false;
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        var cloud;
        try { cloud = f.wx && f.wx.cloud; } catch(e) { cloud = null; }
        if (!cloud || typeof cloud.init !== 'function') continue;

        var env = this._getEnvFromFrame(f);
        if (Array.isArray(env)) env = env[0];

        var opts = {};
        if (typeof env === 'string' && env) opts.env = env;
        else if (env && typeof env === 'object' && env.env) opts.env = env.env;

        try {
          if (!(cloud._config || cloud.inited)) {
            cloud.init(opts);
          }
        } catch(e) {}

        if (cloud._config || cloud.inited) initedAny = true;
      }
      return initedAny;
    },

    // ── 手动调用云函数 ──
    callFunction: function(name, data) {
      this.ensureCloudInit();
      // 从已 hook 的 cloud 中找一个可用的 callFunction
      var caller = null;
      for (var i = 0; i < this._hookedClouds.length; i++) {
        var entry = this._hookedClouds[i];
        if (entry.origMethods['callFunction']) {
          caller = entry.origMethods['callFunction'];
          break;
        }
      }
      if (!caller) {
        // 没 hook 过则尝试直接找
        var frames = this._findAllFrames();
        for (var i = 0; i < frames.length; i++) {
          try {
            if (frames[i].wx && frames[i].wx.cloud && frames[i].wx.cloud.callFunction) {
              caller = frames[i].wx.cloud.callFunction.bind(frames[i].wx.cloud);
              break;
            }
          } catch(e) {}
        }
      }
      if (!caller) return Promise.resolve({ ok: false, reason: 'wx.cloud not available' });

      return new Promise(function(resolve) {
        var t = setTimeout(function() {
          resolve({ ok: true, status: 'timeout', error: '调用超时(10s)' });
        }, 10000);
        caller({
          name: name, data: data || {},
          success: function(res) {
            clearTimeout(t);
            try { resolve({ ok: true, status: 'success', result: JSON.parse(JSON.stringify(res && res.result ? res.result : res)) }); }
            catch(e) { resolve({ ok: true, status: 'success', result: String(res) }); }
          },
          fail: function(err) {
            clearTimeout(t);
            resolve({ ok: true, status: 'fail', error: err ? (err.errMsg || JSON.stringify(err)) : 'unknown' });
          }
        });
      });
    }
  };

  window.cloudAudit = cloudAudit;
})();
