import asyncio, sys, json, logging, warnings
logging.getLogger("cdp_use").setLevel(logging.ERROR)
warnings.filterwarnings("ignore")
sys.path.insert(0, "/Users/cherry/Desktop/WMP/miniapp-reverse-mcp/src")
from miniapp_cdp.mcp_server import MiniappCDPMCP

TARGET = "/packages/service_lineup/pages/service_lineup/service_lineup"

HOOK_JS = r"""
(function(){
  if (globalThis.__bypassInstalled) return 'already';
  var origRedirect = wx.redirectTo.bind(wx);
  var origNavigate = wx.navigateTo.bind(wx);
  var origReLaunch = wx.reLaunch.bind(wx);
  function rewrite(url){
    if (!url) return url;
    if (url.indexOf('stopPC') >= 0 || url.indexOf('network_busy') >= 0) {
      console.log('[bypass] rewrite nav', url, '->', target);
      return target;
    }
    return url;
  }
  var target = %r;
  wx.redirectTo = function(opts){
    if (opts && typeof opts === 'object') {
      var o = Object.assign({}, opts, {url: rewrite(opts.url)});
      return origRedirect(o);
    }
    return origRedirect(opts);
  };
  wx.navigateTo = function(opts){
    if (opts && typeof opts === 'object') {
      var o = Object.assign({}, opts, {url: rewrite(opts.url)});
      return origNavigate(o);
    }
    return origNavigate(opts);
  };
  wx.reLaunch = function(opts){
    if (opts && typeof opts === 'object') {
      var o = Object.assign({}, opts, {url: rewrite(opts.url)});
      return origReLaunch(o);
    }
    return origReLaunch(opts);
  };
  globalThis.__bypassInstalled = true;
  globalThis.__origRedirect = origRedirect;
  globalThis.__origNavigate = origNavigate;
  globalThis.__origReLaunch = origReLaunch;
  return 'installed';
})()
""" % json.dumps(TARGET)

async def call(app, col, ctx, expr, timeout=10):
    r = await asyncio.wait_for(col.evaluate_script(expr, context_id=ctx), timeout)
    return r

async def main():
    app = MiniappCDPMCP()
    await app.list_scripts()
    col = app.network_capture.collector
    ctx = None
    for sid, s in col.scripts.items():
        if s.url and 'appservice.app.js' in s.url:
            ctx = s.execution_context_id; break
    if ctx is None:
        print("NO_APPSERVICE_CTX"); return
    print("ctx", ctx)

    r = await call(app, col, ctx, HOOK_JS)
    print("hook:", r.get("result",{}).get("value"), "exc:", r.get("exceptionDetails"))

    # navigate to the real lineup page
    nav = "wx.redirectTo({url:%s}); 'nav-ok'" % json.dumps(TARGET)
    r = await call(app, col, ctx, nav)
    print("nav:", r.get("result",{}).get("value"), "exc:", r.get("exceptionDetails"))

    await asyncio.sleep(4)

    state = "JSON.stringify({route:(typeof __wxRoute!=='undefined'?__wxRoute:null), file:(typeof __wxAppCurrentFile__!=='undefined'?__wxAppCurrentFile__:null), pages:(typeof getCurrentPages==='function'?(getCurrentPages().map(p=>p.route)):null), loginStatus:wx.getStorageSync('loginStatus')})"
    r = await call(app, col, ctx, state)
    print("state:", r.get("result",{}).get("value"))

asyncio.run(main())
