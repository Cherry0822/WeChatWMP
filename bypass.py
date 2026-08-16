#!/usr/bin/env python
"""
泡泡玛特小程序 PC 端 stopPC 限制绕过脚本(运行时补丁,不改包)。
用法:
    /Users/cherry/Desktop/WMP/miniapp-reverse-mcp/.venv/bin/python /Users/cherry/Desktop/WMP/bypass.py

效果:
    1) 拦截 wx.redirectTo/navigateTo/reLaunch,把 stopPC / network_busy 改写到排队页;
    2) 若当前停在排队页,直接放行到首页 pages/index;
    3) 打印最终页面栈,确认已进入主界面。
注意:
    小程序重新打开后补丁会失效,重新运行本脚本即可。
"""
import asyncio, sys, json, logging, warnings
logging.getLogger("cdp_use").setLevel(logging.ERROR)
warnings.filterwarnings("ignore")
sys.path.insert(0, "/Users/cherry/Desktop/WMP/miniapp-reverse-mcp/src")
from miniapp_cdp.mcp_server import MiniappCDPMCP

LINEUP = "/packages/service_lineup/pages/service_lineup/service_lineup"
INDEX = "/pages/index"

NAV_HOOK = r"""
(function(){
  var target = %r;
  if (!globalThis.__bypassNavInstalled) {
    var origRedirect = wx.redirectTo.bind(wx);
    var origNavigate = wx.navigateTo.bind(wx);
    var origReLaunch = wx.reLaunch.bind(wx);
    function rewrite(url){
      if (url && (url.indexOf('stopPC') >= 0 || url.indexOf('network_busy') >= 0)) {
        console.log('[bypass] rewrite', url, '->', target);
        return target;
      }
      return url;
    }
    wx.redirectTo = function(opts){
      if (opts && typeof opts === 'object') return origRedirect(Object.assign({}, opts, {url: rewrite(opts.url)}));
      return origRedirect(opts);
    };
    wx.navigateTo = function(opts){
      if (opts && typeof opts === 'object') return origNavigate(Object.assign({}, opts, {url: rewrite(opts.url)}));
      return origNavigate(opts);
    };
    wx.reLaunch = function(opts){
      if (opts && typeof opts === 'object') return origReLaunch(Object.assign({}, opts, {url: rewrite(opts.url)}));
      return origReLaunch(opts);
    };
    globalThis.__bypassNavInstalled = true;
  }
  return 'nav-hook-ok';
})()
""" % json.dumps(LINEUP)

async def call(col, expr, ctx, timeout=12):
    return await asyncio.wait_for(col.evaluate_script(expr, context_id=ctx), timeout)

async def main():
    app = MiniappCDPMCP()
    await app.list_scripts()
    col = app.network_capture.collector

    ctx = None
    for sid, s in col.scripts.items():
        if s.url and 'appservice.app.js' in s.url:
            ctx = s.execution_context_id
            break
    if ctx is None:
        print("[!] 未找到 AppService 上下文,请确认小程序已打开")
        return

    # 1) 安装导航重写
    r = await call(col, NAV_HOOK, ctx)
    print("[1/3] 导航补丁:", r.get("result", {}).get("value"))

    # 2) 若当前在 stopPC / 排队页,进入主界面
    r = await call(col, r"""
      (function(){
        var pages = (typeof getCurrentPages==='function') ? getCurrentPages() : [];
        var route = pages.length ? pages[pages.length-1].route : (typeof __wxRoute!=='undefined'?__wxRoute:null);
        if (route && route.indexOf('stopPC') >= 0) {
          wx.redirectTo({url: %s});
          return 'redirect-to-lineup';
        }
        if (route && route.indexOf('service_lineup') >= 0) {
          var p = pages[pages.length-1];
          if (p.serverStatusTimeout) { clearTimeout(p.serverStatusTimeout); p.serverStatusTimeout = null; }
          p.getServiceStatus = function(){ console.log('[bypass] lineup -> index'); wx.switchTab({url: %s}); };
          setTimeout(function(){ wx.switchTab({url: %s}); }, 500);
          return 'lineup-to-index';
        }
        return 'already:' + route;
      })()
    """ % (json.dumps(LINEUP), json.dumps(INDEX), json.dumps(INDEX)), ctx)
    print("[2/3] 页面处理:", r.get("result", {}).get("value"), "exc:", r.get("exceptionDetails"))

    await asyncio.sleep(2)

    # 3) 报告最终页面栈
    r = await call(col, r"""
      JSON.stringify({
        pages: (typeof getCurrentPages==='function' ? getCurrentPages().map(function(p){return p.route;}) : null),
        route: (typeof __wxRoute!=='undefined' ? __wxRoute : null),
        loginStatus: wx.getStorageSync('loginStatus')
      })
    """, ctx)
    print("[3/3] 当前页面栈:", r.get("result", {}).get("value"))

asyncio.run(main())
