(function() {
  // 允许重新注入以支持切换小程序
  if (window._navInjected && window.nav && window.nav.wxFrame) {
    // 检测 wxFrame 是否仍有效
    try {
      var testConfig = window.nav.wxFrame.__wxConfig;
      if (testConfig && testConfig.pages) return; // 仍有效，跳过
    } catch(e) {}
  }
  window._navInjected = true;

  class UniversalMiniProgramNavigator {
    constructor() {
      this.wxFrame = null;
      this.config = null;
      this.allPages = [];
      this.tabBarPages = [];
      this.categorizedPages = {};
      this.menuItems = [];
      this._customHeaders = {};
      this._redirectGuard = false;
      this._blockedRedirects = [];
      this.init();
    }

    init() {
      if (!this.detectMiniProgramEnvironment()) {
        console.error('未检测到小程序环境');
        return;
      }
      this.loadConfiguration();
      this.categorizePages();
    }

    detectMiniProgramEnvironment() {
      if (typeof wx !== 'undefined' && typeof getCurrentPages !== 'undefined') {
        this.wxFrame = window;
        return true;
      }
      if (typeof window !== 'undefined' && window.frames) {
        for (let i = 0; i < window.frames.length; i++) {
          try {
            const frame = window.frames[i];
            if (frame.wx && frame.__wxConfig) {
              this.wxFrame = frame;
              return true;
            }
          } catch (e) {}
        }
      }
      try {
        if (window.parent && window.parent.frames) {
          for (let i = 0; i < window.parent.frames.length; i++) {
            try {
              const frame = window.parent.frames[i];
              if (frame.wx && frame.__wxConfig) {
                this.wxFrame = frame;
                return true;
              }
            } catch (e) {}
          }
        }
      } catch (e) {}
      return false;
    }

    loadConfiguration() {
      this.config = this.wxFrame.__wxConfig;
      this.allPages = [].concat(this.config.pages || []);

      // 补充分包页面
      var subPkgs = this.config.subPackages || this.config.subpackages || [];
      var allPages = this.allPages;
      subPkgs.forEach(function(pkg) {
        (pkg.pages || []).forEach(function(page) {
          var fullPath = pkg.root + '/' + page;
          if (allPages.indexOf(fullPath) === -1) {
            allPages.push(fullPath);
          }
        });
      });

      // 去重
      var seen = {};
      this.allPages = this.allPages.filter(function(p) {
        if (seen[p]) return false;
        seen[p] = true;
        return true;
      });

      if (this.config.tabBar && this.config.tabBar.list) {
        this.tabBarPages = this.config.tabBar.list.map(function(tab) {
          return tab.pagePath.replace('.html', '');
        });
      }
    }

    categorizePages() {
      this.categorizedPages = {
        tabbar: [], auth: [], home: [], list: [], detail: [],
        form: [], user: [], order: [], payment: [], setting: [], other: []
      };
      var self = this;
      this.tabBarPages.forEach(function(page) {
        self.categorizedPages.tabbar.push({
          url: page, name: page, method: 'switchTab', type: 'tabbar'
        });
      });
      var categoryKeywords = {
        auth: ['login', 'register', 'auth', 'sign', 'entry', 'bridge'],
        home: ['home', 'index', 'main', 'dashboard'],
        list: ['list', 'List'],
        detail: ['detail', 'Detail', 'info', 'Info'],
        form: ['form', 'Form', 'add', 'Add', 'edit', 'Edit', 'confirm'],
        user: ['user', 'User', 'profile', 'Profile', 'person'],
        order: ['order', 'Order', 'transaction', 'record'],
        payment: ['pay', 'Pay', 'payment', 'recharge'],
        setting: ['setting', 'Setting', 'config', 'Config']
      };
      this.allPages.forEach(function(page) {
        if (self.tabBarPages.includes(page)) return;
        var pageInfo = { url: page, name: page, method: 'navigateTo', type: 'normal' };
        var categorized = false;
        for (var category in categoryKeywords) {
          var keywords = categoryKeywords[category];
          if (keywords.some(function(kw) { return page.toLowerCase().includes(kw.toLowerCase()); })) {
            self.categorizedPages[category].push(pageInfo);
            categorized = true;
            break;
          }
        }
        if (!categorized) self.categorizedPages.other.push(pageInfo);
      });
      // Build flat menuItems
      var items = [];
      Object.keys(this.categorizedPages).forEach(function(cat) {
        self.categorizedPages[cat].forEach(function(p) { items.push(p); });
      });
      this.menuItems = items;
    }

    // 获取原始导航方法（绕过防跳转 hook）
    _getNav(method) {
      if (this._redirectGuard) {
        if (method === 'redirectTo' && this._origRedirectTo) return this._origRedirectTo;
        if (method === 'reLaunch' && this._origReLaunch) return this._origReLaunch;
        if (method === 'navigateTo' && this._origNavigateTo) return this._origNavigateTo;
      }
      return this.wxFrame.wx[method];
    }

    goTo(url) {
      var isTabBar = this.tabBarPages.some(function(page) {
        return page === url || page === url.replace('/', '') || ('/' + page) === url;
      });
      var options = {
        url: url.startsWith('/') ? url : '/' + url,
        success: function() {},
        fail: function() {}
      };
      if (isTabBar) {
        this.wxFrame.wx.switchTab(options);
      } else {
        this._getNav('navigateTo').call(this.wxFrame.wx, options);
      }
    }

    _safeNavigate(pageUrl) {
      var self = this;
      return new Promise(function(resolve) {
        var url = pageUrl.startsWith('/') ? pageUrl : '/' + pageUrl;
        self._getNav('reLaunch').call(self.wxFrame.wx, {
          url: url,
          success: function() { resolve(true); },
          fail: function() {
            self.wxFrame.wx.switchTab({
              url: url,
              success: function() { resolve(true); },
              fail: function() {
                self._getNav('redirectTo').call(self.wxFrame.wx, {
                  url: url,
                  success: function() { resolve(true); },
                  fail: function() { resolve(false); }
                });
              }
            });
          }
        });
      });
    }

    back(delta) {
      delta = delta || 1;
      this.wxFrame.wx.navigateBack({
        delta: delta,
        success: function() {},
        fail: function() {}
      });
    }

    current() {
      try {
        if (this.wxFrame.getCurrentPages) {
          var pages = this.wxFrame.getCurrentPages();
          if (pages.length > 0) {
            var cur = pages[pages.length - 1];
            return cur.route || cur.__route__ || '';
          }
        }
        return '';
      } catch (e) {
        return '';
      }
    }

    _installHook() {
      if (this._hooked) return;
      this._hooked = true;
      this._capturedAPIs = [];
      this._allCapturedAPIs = {};
      this._globalAPIs = [];
      this._globalAPISet = new Set();
      var wx = this.wxFrame.wx;
      var self = this;
      var methods = ['request', 'uploadFile', 'downloadFile'];
      this._originalMethods = {};
      methods.forEach(function(method) {
        if (wx[method]) {
          self._originalMethods[method] = wx[method];
          wx[method] = function(options) {
            var reqMethod = (options.method || (method === 'request' ? 'GET' : method)).toUpperCase();
            var url = options.url || '';
            var apiInfo = { url: url, method: reqMethod, timestamp: new Date().toLocaleTimeString(), type: method };
            self._capturedAPIs.push(apiInfo);
            var dedupeKey = reqMethod + '|' + self._extractPath(url);
            if (!self._globalAPISet.has(dedupeKey)) {
              self._globalAPISet.add(dedupeKey);
              self._globalAPIs.push(apiInfo);
            }
            // merge custom headers
            if (self._customHeaders && Object.keys(self._customHeaders).length > 0) {
              options.header = options.header || {};
              for (var hk in self._customHeaders) {
                if (self._customHeaders.hasOwnProperty(hk)) {
                  options.header[hk] = self._customHeaders[hk];
                }
              }
            }
            return self._originalMethods[method].call(wx, options);
          };
        }
      });
    }

    _uninstallHook() {
      if (!this._hooked) return;
      var wx = this.wxFrame.wx;
      var self = this;
      Object.keys(this._originalMethods).forEach(function(method) {
        wx[method] = self._originalMethods[method];
      });
      this._hooked = false;
    }

    _extractPath(url) {
      if (!this._pathCache) this._pathCache = {};
      if (this._pathCache[url]) return this._pathCache[url];
      var path;
      try { path = new URL(url).pathname; } catch(e) { path = url.split('?')[0]; }
      this._pathCache[url] = path;
      return path;
    }

    _sleep(ms) {
      return new Promise(function(resolve) { setTimeout(resolve, ms); });
    }

    stopAutoVisit() {
      this._isAutoVisiting = false;
    }

    getAPIs() {
      return this._globalAPIs || [];
    }

    getResults() {
      return this._autoVisitResults || {};
    }

    enableRedirectGuard() {
      if (this._redirectGuard) return {ok:true, already:true};
      this._redirectGuard = true;
      this._blockedRedirects = [];
      var wx = this.wxFrame.wx;
      var self = this;
      this._origRedirectTo = wx.redirectTo;
      this._origReLaunch = wx.reLaunch;
      this._origNavigateTo = wx.navigateTo;
      // hook redirectTo — 拦截强制跳转，调用 success 防止页面卡死
      wx.redirectTo = function(options) {
        var url = (options && options.url) || '';
        self._blockedRedirects.push({type:'redirectTo', url:url, time:new Date().toLocaleTimeString()});
        console.warn('[防跳转] 已拦截 redirectTo:', url);
        if (options && options.success) options.success({errMsg:'redirectTo:ok'});
        if (options && options.complete) options.complete({errMsg:'redirectTo:ok'});
      };
      // hook reLaunch — 拦截强制重启
      wx.reLaunch = function(options) {
        var url = (options && options.url) || '';
        self._blockedRedirects.push({type:'reLaunch', url:url, time:new Date().toLocaleTimeString()});
        console.warn('[防跳转] 已拦截 reLaunch:', url);
        if (options && options.success) options.success({errMsg:'reLaunch:ok'});
        if (options && options.complete) options.complete({errMsg:'reLaunch:ok'});
      };
      // hook navigateTo — 拦截跳转新页面
      wx.navigateTo = function(options) {
        var url = (options && options.url) || '';
        self._blockedRedirects.push({type:'navigateTo', url:url, time:new Date().toLocaleTimeString()});
        console.warn('[防跳转] 已拦截 navigateTo:', url);
        if (options && options.success) options.success({errMsg:'navigateTo:ok'});
        if (options && options.complete) options.complete({errMsg:'navigateTo:ok'});
      };
      return {ok:true};
    }

    disableRedirectGuard() {
      if (!this._redirectGuard) return;
      this._redirectGuard = false;
      var wx = this.wxFrame.wx;
      if (this._origRedirectTo) wx.redirectTo = this._origRedirectTo;
      if (this._origReLaunch) wx.reLaunch = this._origReLaunch;
      if (this._origNavigateTo) wx.navigateTo = this._origNavigateTo;
      this._origRedirectTo = null;
      this._origReLaunch = null;
      this._origNavigateTo = null;
    }

    getBlockedRedirects() {
      return this._blockedRedirects || [];
    }

    isRedirectGuardOn() {
      return !!this._redirectGuard;
    }
  }

  try {
    window.nav = new UniversalMiniProgramNavigator();
  } catch (e) {
    console.error('Navigator init failed:', e.message);
  }
})();
