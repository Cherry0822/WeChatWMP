from __future__ import annotations

import json

from ..network_capture import NetworkCaptureService
from .navigator_tools import ensure_navigator, _eval_json


async def set_miniapp_debug(
    network_capture: NetworkCaptureService,
    enable: bool,
) -> str:
    collector = await ensure_navigator(network_capture)
    flag = "true" if enable else "false"
    expression = (
        "(function(){"
        "try{"
        "var nav=window.nav;"
        "if(!nav||!nav.wxFrame||!nav.wxFrame.wx)return JSON.stringify({err:'no wxFrame'});"
        f"nav.wxFrame.wx.setEnableDebug({{enableDebug:{flag},"
        "success:function(){},fail:function(e){}});"
        "return JSON.stringify({ok:true})"
        "}catch(e){return JSON.stringify({err:e.message})}"
        "})()"
    )
    value = await _eval_json(collector, expression)
    if value.get("err"):
        raise RuntimeError(value["err"])
    return json.dumps(value, ensure_ascii=False)


async def get_miniapp_debug_state(network_capture: NetworkCaptureService) -> str:
    collector = await ensure_navigator(network_capture)
    expression = (
        "(function(){"
        "try{"
        "var f=window.nav&&window.nav.wxFrame?window.nav.wxFrame:window;"
        "var c=f.__wxConfig||{};var d=!!c.debug;"
        "var v=!!(f.document&&f.document.getElementById('__vconsole'));"
        "return JSON.stringify({debug:d,vconsole:v})"
        "}catch(e){return JSON.stringify({err:e.message})}"
        "})()"
    )
    value = await _eval_json(collector, expression)
    return json.dumps(value, ensure_ascii=False)
