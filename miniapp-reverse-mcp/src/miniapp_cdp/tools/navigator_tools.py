from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from ..network_capture import NetworkCaptureService


_NAV_JS_PATH = Path(__file__).resolve().parent.parent / "nav_inject.js"
_NAV_JS = _NAV_JS_PATH.read_text(encoding="utf-8")


async def ensure_navigator(network_capture: NetworkCaptureService):
    await network_capture.ensure_monitoring()
    collector = network_capture.collector
    if collector is None:
        raise RuntimeError("Debugger not connected")
    await collector.evaluate_script(_NAV_JS, return_by_value=True, await_promise=True)
    return collector


async def _eval_json(collector, expression: str) -> dict[str, Any]:
    result = await collector.evaluate_script(
        expression,
        return_by_value=True,
        await_promise=True,
    )
    exception = result.get("exceptionDetails")
    if exception:
        raise RuntimeError(exception.get("exception", {}).get("description", "evaluation failed"))
    remote = result.get("result", {})
    value = remote.get("value")
    if value is None:
        raise RuntimeError(remote.get("description", "no return value"))
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False)
    return json.loads(value)


async def get_miniapp_route_config(network_capture: NetworkCaptureService) -> str:
    collector = await ensure_navigator(network_capture)
    expression = (
        "JSON.stringify({"
        "pages:window.nav?window.nav.allPages:[],"
        "tabBar:window.nav?window.nav.tabBarPages:[],"
        "appid:(function(){try{"
        "var cfg=window.nav&&window.nav.config?window.nav.config:{};"
        "return cfg.appId||cfg.appid||(cfg.accountInfo&&cfg.accountInfo.appId)||''"
        "}catch(e){return ''}})(),"
        "entry:window.nav&&window.nav.config?(window.nav.config.entryPagePath||''):'',"
        "name:(function(){try{"
        "var f=window.nav&&window.nav.wxFrame;"
        "var a=(f&&f.__wxConfig)||window.__wxConfig||"
        "(window.wx&&window.wx.__wxConfig)||{};"
        "var acc=a.accountInfo||{};"
        "return acc.nickname||acc.appName||a.appName||a.appname||''"
        "}catch(e){return ''}})(),"
        "current:window.nav?window.nav.current():''"
        "})"
    )
    config = await _eval_json(collector, expression)
    return json.dumps(config, ensure_ascii=False)


async def navigate_miniapp(
    network_capture: NetworkCaptureService,
    action: str,
    route: str | None = None,
    delta: int = 1,
) -> str:
    collector = await ensure_navigator(network_capture)
    safe_route = (route or "").replace("\\", "\\\\").replace("'", "\\'")

    if action == "current":
        expression = "JSON.stringify({route:window.nav?window.nav.current():''})"
        value = await _eval_json(collector, expression)
        return json.dumps(value, ensure_ascii=False)

    if action == "navigate":
        expression = f"window.nav.goTo('{safe_route}'); 'ok'"
    elif action == "redirect":
        expression = f"window.nav.wxFrame.wx.redirectTo({{url:'/{safe_route}'}}); 'ok'"
    elif action == "relaunch":
        expression = f"window.nav._safeNavigate('{safe_route}'); 'ok'"
    elif action == "back":
        expression = f"window.nav.back({int(delta)}); 'ok'"
    elif action == "refresh":
        expression = (
            "(function(){"
            "var nav=window.nav;if(!nav||!nav.wxFrame)return 'no nav';"
            "var p=nav.wxFrame.getCurrentPages();"
            "if(!p||!p.length)return 'no page';"
            "var cur=p[p.length-1];var route=cur.route||cur.__route__||'';"
            "if(!route)return 'no route';var url='/'+route;"
            "var opts=cur.options||{};"
            "var qs=Object.keys(opts).map(function(k){return k+'='+opts[k]}).join('&');"
            "if(qs)url+='?'+qs;"
            "nav.wxFrame.wx.reLaunch({url:url,success:function(){},fail:function(e){"
            "nav.wxFrame.wx.redirectTo({url:url,success:function(){},fail:function(){}})"
            "}});return 'ok';"
            "})()"
        )
    else:
        raise ValueError("action must be current, navigate, redirect, relaunch, back, or refresh")

    result = await collector.evaluate_script(expression, return_by_value=True, await_promise=True)
    remote = result.get("result", {})
    value = remote.get("value")
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


async def set_miniapp_redirect_guard(
    network_capture: NetworkCaptureService,
    enabled: bool,
) -> str:
    collector = await ensure_navigator(network_capture)
    if enabled:
        expression = "JSON.stringify(window.nav.enableRedirectGuard())"
    else:
        expression = "window.nav.disableRedirectGuard(); JSON.stringify({ok:true})"
    value = await _eval_json(collector, expression)
    return json.dumps(value, ensure_ascii=False)


async def list_miniapp_blocked_redirects(network_capture: NetworkCaptureService) -> str:
    collector = await ensure_navigator(network_capture)
    value = await _eval_json(collector, "JSON.stringify(window.nav.getBlockedRedirects())")
    return json.dumps(value, ensure_ascii=False)
