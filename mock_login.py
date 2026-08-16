#!/usr/bin/env python
"""
泡泡玛特小程序 PC 端 mock 登录脚本(前端状态模拟)。
配合 bypass.py 使用:先绕过 stopPC,再注入登录态,让会员页可导航、可触发业务请求。

用法:
    /Users/cherry/Desktop/WMP/miniapp-reverse-mcp/.venv/bin/python /Users/cherry/Desktop/WMP/mock_login.py

说明:
    - 这只设置前端登录态(loginStatus/userId/providerId/login_token 等)。
    - 后端 new/* 接口在 PC 端仍会被网关以 432 拦截,所以数据不会返回;
      但页面可进入、可触发真实请求,便于抓包/断点分析签名与参数。
"""
import asyncio, sys, json, logging, warnings
logging.getLogger("cdp_use").setLevel(logging.ERROR)
warnings.filterwarnings("ignore")
sys.path.insert(0, "/Users/cherry/Desktop/WMP/miniapp-reverse-mcp/src")
from miniapp_cdp.mcp_server import MiniappCDPMCP

MOCK = r"""
(function(){
  var app = getApp();
  var openid = 'mock_openid_123456';
  var user_id = '88888888';
  var phone = '13800138000';
  var union_id = 'mock_unionid_123';
  var token = 'mock_login_token_123';
  var now = Date.now();
  wx.setStorageSync('loginStatus', true);
  wx.setStorageSync('userId', user_id);
  wx.setStorageSync('providerId', openid);
  wx.setStorageSync('userPhone', phone);
  wx.setStorageSync('prod__app:login_token', {data: token, expiry: now + 31536000000});
  app.globalData.userInfo = {openid: openid, user_id: user_id, phone: phone, union_id: union_id, providerId: openid, first_login: 1};
  app.globalData.phone = phone;
  app.globalData.userId = user_id;
  app.globalData.isAppLogin = true;
  try { app.changeIsLogin(true); } catch(e){}
  try { app.changeUnionid(union_id); } catch(e){}
  try { app.changeLoginDone(true); } catch(e){}
  try { app.changeGlobalUser(app.globalData.userInfo); } catch(e){}
  return 'mock-login-done';
})()
"""

async def call(col, expr, ctx, timeout=15):
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

    r = await call(col, MOCK, ctx)
    print("[1/2] mock login:", r.get("result", {}).get("value"), "exc:", r.get("exceptionDetails"))

    r = await call(col, r"""
      JSON.stringify({
        loginStatus: wx.getStorageSync('loginStatus'),
        userId: wx.getStorageSync('userId'),
        providerId: wx.getStorageSync('providerId'),
        userPhone: wx.getStorageSync('userPhone'),
        isAppLogin: getApp().globalData.isAppLogin,
        pages: (typeof getCurrentPages==='function' ? getCurrentPages().map(function(p){return p.route;}) : null)
      })
    """, ctx)
    print("[2/2] state:", r.get("result", {}).get("value"))

asyncio.run(main())
