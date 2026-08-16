r"""
extractor.py — 敏感信息提取引擎
直接使用 heartk_fast.py 的完整正则规则，保证提取结果一致
支持自定义正则规则，自定义类别会出现在导出报告中

用法:
    from src.extractor import Extractor
    ext = Extractor()
    ext.add_custom_pattern("视频", r"video_url\s*=\s*['\"](.+?)['\"]")
    results = ext.scan_directory("/path/to/dir")
    Extractor.export_html(results, "report.html")
"""
import json
import os
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Dict, List, Optional, Any, Callable

try:
    import chardet
except ImportError:
    chardet = None

# ============================================================
# 1. 所有正则规则 (从 heartk_fast.py 原封不动复制)
# ============================================================

STATIC_EXTENSIONS = ['.jpg', '.png', '.gif', '.css', '.svg', '.ico', '.js']

CATEGORIES = [
    "ip", "ip_port", "domain", "path", "incomplete_path",
    "url", "sfz", "mobile", "mail", "jwt", "algorithm", "secret", "static"
]

# ---------- extract_info 对应的正则 ----------

EXTRACT_PATTERNS: Dict[str, re.Pattern] = {
    'sfz': re.compile(
        r"""['"]((\d{8}(0\d|10|11|12)([0-2]\d|30|31)\d{3})|(\d{6}(18|19|20)\d{2}(0[1-9]|10|11|12)([0-2]\d|30|31)\d{3}(\d|X|x)))['"]"""),
    'mobile': re.compile(
        r"""['\"](1(3([0-35-9]\d|4[1-8])|4[14-9]\d|5([\d]\d|7[1-79])|66\d|7[2-35-8]\d|8\d{2}|9[89]\d)\d{7})['\"]"""),
    'mail': re.compile(
        r"""['\"][a-zA-Z0-9\._\-]*@[a-zA-Z0-9\._\-]{1,63}\.((?!js|css|jpg|jpeg|png|ico)[a-zA-Z]{2,})['\"]"""),
    'ip': re.compile(
        r"""['\"](([a-zA-Z0-9]+:)?\/\/)?\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(\/.*?)?['\"]"""),
    'ip_port': re.compile(
        r"""['\"](([a-zA-Z0-9]+:)?\/\/)?\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\:\d{1,5}(\/.*?)?['\"]"""),
    'domain': re.compile(
        r"""['\"](([a-zA-Z0-9]+:)?\/\/)?[a-zA-Z0-9\-\.]*?\.(xin|com|cn|net|com\.cn|vip|top|cc|shop|club|wang|xyz|luxe|site|news|pub|fun|online|win|red|loan|ren|mom|net\.cn|org|link|biz|bid|help|tech|date|mobi|so|me|tv|co|vc|pw|video|party|pics|website|store|ltd|ink|trade|live|wiki|space|gift|lol|work|band|info|click|photo|market|tel|social|press|game|kim|org\.cn|games|pro|men|love|studio|rocks|asia|group|science|design|software|engineer|lawyer|fit|beer|tw|我爱你|中国|公司|网络|在线|网址|网店|集团|中文网)(\:\d{1,5})?(\/)?['\"]"""),
    'path': re.compile(
        r"""['\"](?:\/|\.\.\/)(?:[^\/\>\< \)\(\{\}\,\'\"\\\n][^\>\< \)\(\{\}\,\'\"\\\n]*?)['\"]"""),
    'incomplete_path': re.compile(
        r"""['\"][^\/\>\< \)\(\{\}\,\'\"\\\n][\w\/]*?\/[\w\/]*?['\"]"""),
    'url': re.compile(
        r"""['\"](([a-zA-Z0-9]+:)?\/\/)?[a-zA-Z0-9\-\.]*?\.(xin|com|cn|net|com\.cn|vip|top|cc|shop|club|wang|xyz|luxe|site|news|pub|fun|online|win|red|loan|ren|mom|net\.cn|org|link|biz|bid|help|tech|date|mobi|so|me|tv|co|vc|pw|video|party|pics|website|store|ltd|ink|trade|live|wiki|space|gift|lol|work|band|info|click|photo|market|tel|social|press|game|kim|org\.cn|games|pro|men|love|studio|rocks|asia|group|science|design|software|engineer|lawyer|fit|beer|tw|我爱你|中国|公司|网络|在线|网址|网店|集团|中文网)(\:\d{1,5})?(\/.*?)?['\"]"""),
    'jwt': re.compile(
        r"""['\"](ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}|ey[A-Za-z0-9_\/+-]{10,}\.[A-Za-z0-9._\/+-]{10,})['\"]"""),
    'algorithm': re.compile(
        r"""\W(Base64\.encode|Base64\.decode|btoa|atob|CryptoJS\.AES|CryptoJS\.DES|JSEncrypt|rsa|KJUR|\$\.md5|md5|sha1|sha256|sha512)[\(\.]""", re.IGNORECASE),
}

# ---------- nuclei_regex (727条秘密检测规则) ----------

_NUCLEI_REGEX_SOURCES = [
    "zopim[_-]?account[_-]?key", "zhuliang[_-]?gh[_-]?token",
    "zensonatypepassword", "zendesk[_-]?travis[_-]?github",
    "yt[_-]?server[_-]?api[_-]?key", "yt[_-]?partner[_-]?refresh[_-]?token",
    "yt[_-]?partner[_-]?client[_-]?secret", "yt[_-]?client[_-]?secret",
    "yt[_-]?api[_-]?key", "yt[_-]?account[_-]?refresh[_-]?token",
    "yt[_-]?account[_-]?client[_-]?secret", "yangshun[_-]?gh[_-]?token",
    "yangshun[_-]?gh[_-]?password", "www[_-]?googleapis[_-]?com",
    "wpt[_-]?ssh[_-]?private[_-]?key[_-]?base64", "wpt[_-]?ssh[_-]?connect",
    "wpt[_-]?report[_-]?api[_-]?key", "wpt[_-]?prepare[_-]?dir",
    "wpt[_-]?db[_-]?user", "wpt[_-]?db[_-]?password", "wporg[_-]?password",
    "wpjm[_-]?phpunit[_-]?google[_-]?geocode[_-]?api[_-]?key",
    "wordpress[_-]?db[_-]?user", "wordpress[_-]?db[_-]?password",
    "wincert[_-]?password", "widget[_-]?test[_-]?server",
    "widget[_-]?fb[_-]?password[_-]?3", "widget[_-]?fb[_-]?password[_-]?2",
    "widget[_-]?fb[_-]?password",
    "widget[_-]?basic[_-]?password[_-]?5", "widget[_-]?basic[_-]?password[_-]?4",
    "widget[_-]?basic[_-]?password[_-]?3", "widget[_-]?basic[_-]?password[_-]?2",
    "widget[_-]?basic[_-]?password",
    "watson[_-]?password", "watson[_-]?device[_-]?password",
    "watson[_-]?conversation[_-]?password", "wakatime[_-]?api[_-]?key",
    "vscetoken", "visual[_-]?recognition[_-]?api[_-]?key",
    "virustotal[_-]?apikey", "vip[_-]?github[_-]?deploy[_-]?key[_-]?pass",
    "vip[_-]?github[_-]?deploy[_-]?key",
    "vip[_-]?github[_-]?build[_-]?repo[_-]?deploy[_-]?key",
    "v[_-]?sfdc[_-]?password", "v[_-]?sfdc[_-]?client[_-]?secret",
    "usertravis", "user[_-]?assets[_-]?secret[_-]?access[_-]?key",
    "user[_-]?assets[_-]?access[_-]?key[_-]?id", "use[_-]?ssh",
    "us[_-]?east[_-]?1[_-]?elb[_-]?amazonaws[_-]?com",
    "urban[_-]?secret", "urban[_-]?master[_-]?secret", "urban[_-]?key",
    "unity[_-]?serial", "unity[_-]?password",
    "twitteroauthaccesstoken", "twitteroauthaccesssecret",
    "twitter[_-]?consumer[_-]?secret", "twitter[_-]?consumer[_-]?key",
    "twine[_-]?password", "twilio[_-]?token", "twilio[_-]?sid",
    "twilio[_-]?configuration[_-]?sid",
    "twilio[_-]?chat[_-]?account[_-]?api[_-]?service",
    "twilio[_-]?api[_-]?secret", "twilio[_-]?api[_-]?key",
    "trex[_-]?okta[_-]?client[_-]?token", "trex[_-]?client[_-]?token",
    "travis[_-]?token", "travis[_-]?secure[_-]?env[_-]?vars",
    "travis[_-]?pull[_-]?request", "travis[_-]?gh[_-]?token",
    "travis[_-]?e2e[_-]?token", "travis[_-]?com[_-]?token",
    "travis[_-]?branch", "travis[_-]?api[_-]?token",
    "travis[_-]?access[_-]?token", "token[_-]?core[_-]?java",
    "thera[_-]?oss[_-]?access[_-]?key", "tester[_-]?keys[_-]?password",
    "test[_-]?test", "test[_-]?github[_-]?token", "tesco[_-]?api[_-]?key",
    "svn[_-]?pass", "surge[_-]?token", "surge[_-]?login",
    "stripe[_-]?public", "stripe[_-]?private",
    "strip[_-]?secret[_-]?key", "strip[_-]?publishable[_-]?key",
    "stormpath[_-]?api[_-]?key[_-]?secret", "stormpath[_-]?api[_-]?key[_-]?id",
    "starship[_-]?auth[_-]?token", "starship[_-]?account[_-]?sid",
    "star[_-]?test[_-]?secret[_-]?access[_-]?key", "star[_-]?test[_-]?location",
    "star[_-]?test[_-]?bucket", "star[_-]?test[_-]?aws[_-]?access[_-]?key[_-]?id",
    "staging[_-]?base[_-]?url[_-]?runscope", "ssmtp[_-]?config", "sshpass",
    "srcclr[_-]?api[_-]?token",
    "square[_-]?reader[_-]?sdk[_-]?repository[_-]?password",
    "sqssecretkey", "sqsaccesskey", "spring[_-]?mail[_-]?password",
    "spotify[_-]?api[_-]?client[_-]?secret", "spotify[_-]?api[_-]?access[_-]?token",
    "spaces[_-]?secret[_-]?access[_-]?key", "spaces[_-]?access[_-]?key[_-]?id",
    "soundcloud[_-]?password", "soundcloud[_-]?client[_-]?secret",
    "sonatypepassword", "sonatype[_-]?token[_-]?user",
    "sonatype[_-]?token[_-]?password", "sonatype[_-]?password",
    "sonatype[_-]?pass", "sonatype[_-]?nexus[_-]?password",
    "sonatype[_-]?gpg[_-]?passphrase", "sonatype[_-]?gpg[_-]?key[_-]?name",
    "sonar[_-]?token", "sonar[_-]?project[_-]?key",
    "sonar[_-]?organization[_-]?key",
    "socrata[_-]?password", "socrata[_-]?app[_-]?token",
    "snyk[_-]?token", "snyk[_-]?api[_-]?token",
    "snoowrap[_-]?refresh[_-]?token", "snoowrap[_-]?password",
    "snoowrap[_-]?client[_-]?secret", "slate[_-]?user[_-]?email",
    "slash[_-]?developer[_-]?space[_-]?key", "slash[_-]?developer[_-]?space",
    "signing[_-]?key[_-]?sid", "signing[_-]?key[_-]?secret",
    "signing[_-]?key[_-]?password", "signing[_-]?key",
    "setsecretkey", "setdstsecretkey", "setdstaccesskey",
    "ses[_-]?secret[_-]?key", "ses[_-]?access[_-]?key",
    "service[_-]?account[_-]?secret", "sentry[_-]?key",
    "sentry[_-]?secret", "sentry[_-]?endpoint",
    "sentry[_-]?default[_-]?org", "sentry[_-]?auth[_-]?token",
    "sendwithus[_-]?key", "sendgrid[_-]?username", "sendgrid[_-]?user",
    "sendgrid[_-]?password", "sendgrid[_-]?key", "sendgrid[_-]?api[_-]?key",
    "sendgrid", "selion[_-]?selenium[_-]?host", "selion[_-]?log[_-]?level[_-]?dev",
    "segment[_-]?api[_-]?key", "secretid", "secretkey", "secretaccesskey",
    "secret[_-]?key[_-]?base",
    "secret[_-]?9", "secret[_-]?8", "secret[_-]?7", "secret[_-]?6",
    "secret[_-]?5", "secret[_-]?4", "secret[_-]?3", "secret[_-]?2",
    "secret[_-]?11", "secret[_-]?10", "secret[_-]?1", "secret[_-]?0",
    "sdr[_-]?token", "scrutinizer[_-]?token", "sauce[_-]?access[_-]?key",
    "sandbox[_-]?aws[_-]?secret[_-]?access[_-]?key",
    "sandbox[_-]?aws[_-]?access[_-]?key[_-]?id", "sandbox[_-]?access[_-]?token",
    "salesforce[_-]?bulk[_-]?test[_-]?security[_-]?token",
    "salesforce[_-]?bulk[_-]?test[_-]?password",
    "sacloud[_-]?api", "sacloud[_-]?access[_-]?token[_-]?secret",
    "sacloud[_-]?access[_-]?token",
    "s3[_-]?user[_-]?secret", "s3[_-]?secret[_-]?key",
    "s3[_-]?secret[_-]?assets", "s3[_-]?secret[_-]?app[_-]?logs",
    "s3[_-]?key[_-]?assets", "s3[_-]?key[_-]?app[_-]?logs", "s3[_-]?key",
    "s3[_-]?external[_-]?3[_-]?amazonaws[_-]?com",
    "s3[_-]?bucket[_-]?name[_-]?assets", "s3[_-]?bucket[_-]?name[_-]?app[_-]?logs",
    "s3[_-]?access[_-]?key[_-]?id", "s3[_-]?access[_-]?key",
    "rubygems[_-]?auth[_-]?token", "rtd[_-]?store[_-]?pass", "rtd[_-]?key[_-]?pass",
    "route53[_-]?access[_-]?key[_-]?id",
    "ropsten[_-]?private[_-]?key", "rinkeby[_-]?private[_-]?key",
    "rest[_-]?api[_-]?key", "repotoken",
    "reporting[_-]?webdav[_-]?url", "reporting[_-]?webdav[_-]?pwd",
    "release[_-]?token", "release[_-]?gh[_-]?token",
    "registry[_-]?secure", "registry[_-]?pass", "refresh[_-]?token",
    "rediscloud[_-]?url", "redis[_-]?stunnel[_-]?urls",
    "randrmusicapiaccesstoken", "rabbitmq[_-]?password",
    "quip[_-]?token", "qiita[_-]?token", "pypi[_-]?passowrd",
    "pushover[_-]?token", "publish[_-]?secret", "publish[_-]?key",
    "publish[_-]?access", "project[_-]?config",
    "prod[_-]?secret[_-]?key", "prod[_-]?password", "prod[_-]?access[_-]?key[_-]?id",
    "private[_-]?signing[_-]?password", "pring[_-]?mail[_-]?username",
    "preferred[_-]?username", "prebuild[_-]?auth",
    "postgresql[_-]?pass", "postgresql[_-]?db",
    "postgres[_-]?env[_-]?postgres[_-]?password",
    "postgres[_-]?env[_-]?postgres[_-]?db", "plugin[_-]?password",
    "plotly[_-]?apikey", "places[_-]?apikey", "places[_-]?api[_-]?key",
    "pg[_-]?host", "pg[_-]?database", "personal[_-]?secret", "personal[_-]?key",
    "percy[_-]?token", "percy[_-]?project",
    "paypal[_-]?client[_-]?secret", "passwordtravis", "parse[_-]?js[_-]?key",
    "pagerduty[_-]?apikey", "packagecloud[_-]?token",
    "ossrh[_-]?username", "ossrh[_-]?secret", "ossrh[_-]?password",
    "ossrh[_-]?pass", "ossrh[_-]?jira[_-]?password",
    "os[_-]?password", "os[_-]?auth[_-]?url",
    "org[_-]?project[_-]?gradle[_-]?sonatype[_-]?nexus[_-]?password",
    "org[_-]?gradle[_-]?project[_-]?sonatype[_-]?nexus[_-]?password",
    "openwhisk[_-]?key", "open[_-]?whisk[_-]?key",
    "onesignal[_-]?user[_-]?auth[_-]?key", "onesignal[_-]?api[_-]?key",
    "omise[_-]?skey", "omise[_-]?pubkey", "omise[_-]?pkey", "omise[_-]?key",
    "okta[_-]?oauth2[_-]?clientsecret", "okta[_-]?oauth2[_-]?client[_-]?secret",
    "okta[_-]?client[_-]?token",
    "ofta[_-]?secret", "ofta[_-]?region", "ofta[_-]?key",
    "octest[_-]?password", "octest[_-]?app[_-]?username",
    "octest[_-]?app[_-]?password", "oc[_-]?pass",
    "object[_-]?store[_-]?creds", "object[_-]?store[_-]?bucket",
    "object[_-]?storage[_-]?region[_-]?name", "object[_-]?storage[_-]?password",
    "oauth[_-]?token", "numbers[_-]?service[_-]?pass",
    "nuget[_-]?key", "nuget[_-]?apikey", "nuget[_-]?api[_-]?key",
    "npm[_-]?token", "npm[_-]?secret[_-]?key", "npm[_-]?password",
    "npm[_-]?email", "npm[_-]?auth[_-]?token", "npm[_-]?api[_-]?token",
    "npm[_-]?api[_-]?key", "now[_-]?token", "non[_-]?token",
    "node[_-]?pre[_-]?gyp[_-]?secretaccesskey",
    "node[_-]?pre[_-]?gyp[_-]?github[_-]?token",
    "node[_-]?pre[_-]?gyp[_-]?accesskeyid", "node[_-]?env",
    "ngrok[_-]?token", "ngrok[_-]?auth[_-]?token",
    "nexuspassword", "nexus[_-]?password",
    "new[_-]?relic[_-]?beta[_-]?token", "netlify[_-]?api[_-]?key",
    "nativeevents", "mysqlsecret", "mysqlmasteruser",
    "mysql[_-]?username", "mysql[_-]?user", "mysql[_-]?root[_-]?password",
    "mysql[_-]?password", "mysql[_-]?hostname", "mysql[_-]?database",
    "my[_-]?secret[_-]?env",
    "multi[_-]?workspace[_-]?sid", "multi[_-]?workflow[_-]?sid",
    "multi[_-]?disconnect[_-]?sid", "multi[_-]?connect[_-]?sid",
    "multi[_-]?bob[_-]?sid",
    "minio[_-]?secret[_-]?key", "minio[_-]?access[_-]?key",
    "mile[_-]?zero[_-]?key", "mh[_-]?password", "mh[_-]?apikey",
    "mg[_-]?public[_-]?api[_-]?key", "mg[_-]?api[_-]?key",
    "mapboxaccesstoken",
    "mapbox[_-]?aws[_-]?secret[_-]?access[_-]?key",
    "mapbox[_-]?aws[_-]?access[_-]?key[_-]?id",
    "mapbox[_-]?api[_-]?token", "mapbox[_-]?access[_-]?token",
    "manifest[_-]?app[_-]?url", "manifest[_-]?app[_-]?token",
    "mandrill[_-]?api[_-]?key", "managementapiaccesstoken",
    "management[_-]?token", "manage[_-]?secret", "manage[_-]?key",
    "mailgun[_-]?secret[_-]?api[_-]?key", "mailgun[_-]?pub[_-]?key",
    "mailgun[_-]?pub[_-]?apikey", "mailgun[_-]?priv[_-]?key",
    "mailgun[_-]?password", "mailgun[_-]?apikey", "mailgun[_-]?api[_-]?key",
    "mailer[_-]?password", "mailchimp[_-]?key", "mailchimp[_-]?api[_-]?key",
    "mail[_-]?password", "magento[_-]?password",
    "magento[_-]?auth[_-]?username", "magento[_-]?auth[_-]?password",
    "lottie[_-]?upload[_-]?cert[_-]?key[_-]?store[_-]?password",
    "lottie[_-]?upload[_-]?cert[_-]?key[_-]?password",
    "lottie[_-]?s3[_-]?secret[_-]?key",
    "lottie[_-]?happo[_-]?secret[_-]?key", "lottie[_-]?happo[_-]?api[_-]?key",
    "looker[_-]?test[_-]?runner[_-]?client[_-]?secret",
    "ll[_-]?shared[_-]?key", "ll[_-]?publish[_-]?url",
    "linux[_-]?signing[_-]?key",
    "lighthouse[_-]?api[_-]?key",
    "lektor[_-]?deploy[_-]?username", "lektor[_-]?deploy[_-]?password",
    "leanplum[_-]?key", "kxoltsn3vogdop92m",
    "kubeconfig", "kubecfg[_-]?s3[_-]?path", "kovan[_-]?private[_-]?key",
    "keystore[_-]?pass",
    "kafka[_-]?rest[_-]?url", "kafka[_-]?instance[_-]?name",
    "kafka[_-]?admin[_-]?url", "jwt[_-]?secret",
    "jdbc[_-]?host", "jdbc[_-]?databaseurl",
    "itest[_-]?gh[_-]?token", "ios[_-]?docs[_-]?deploy[_-]?token",
    "internal[_-]?secrets",
    "integration[_-]?test[_-]?appid", "integration[_-]?test[_-]?api[_-]?key",
    "index[_-]?name", "ij[_-]?repo[_-]?username", "ij[_-]?repo[_-]?password",
    "hub[_-]?dxia2[_-]?password", "homebrew[_-]?github[_-]?api[_-]?token",
    "hockeyapp[_-]?token",
    "heroku[_-]?token", "heroku[_-]?email", "heroku[_-]?api[_-]?key",
    "hb[_-]?codesign[_-]?key[_-]?pass", "hb[_-]?codesign[_-]?gpg[_-]?pass",
    "hab[_-]?key", "hab[_-]?auth[_-]?token",
    "grgit[_-]?user", "gren[_-]?github[_-]?token",
    "gradle[_-]?signing[_-]?password", "gradle[_-]?signing[_-]?key[_-]?id",
    "gradle[_-]?publish[_-]?secret", "gradle[_-]?publish[_-]?key",
    "gpg[_-]?secret[_-]?keys", "gpg[_-]?private[_-]?key",
    "gpg[_-]?passphrase", "gpg[_-]?ownertrust",
    "gpg[_-]?keyname", "gpg[_-]?key[_-]?name",
    "google[_-]?private[_-]?key(?:[_-]?id)?",
    "google[_-]?maps[_-]?api[_-]?key", "google[_-]?client[_-]?secret",
    "google[_-]?client[_-]?id", "google[_-]?client[_-]?email",
    "google[_-]?account[_-]?type", "gogs[_-]?password",
    "gitlab[_-]?user[_-]?email",
    "github[_-]?tokens", "github[_-]?token", "github[_-]?repo",
    "github[_-]?release[_-]?token", "github[_-]?pwd", "github[_-]?password",
    "github[_-]?oauth[_-]?token", "github[_-]?oauth", "github[_-]?key",
    "github[_-]?hunter[_-]?username", "github[_-]?hunter[_-]?token",
    "github[_-]?deployment[_-]?token",
    "github[_-]?deploy[_-]?hb[_-]?doc[_-]?pass",
    "github[_-]?client[_-]?secret", "github[_-]?auth[_-]?token",
    "github[_-]?auth", "github[_-]?api[_-]?token", "github[_-]?api[_-]?key",
    "github[_-]?access[_-]?token",
    "git[_-]?token", "git[_-]?name", "git[_-]?email",
    "git[_-]?committer[_-]?name", "git[_-]?committer[_-]?email",
    "git[_-]?author[_-]?name", "git[_-]?author[_-]?email",
    "ghost[_-]?api[_-]?key", "ghb[_-]?token",
    "gh[_-]?unstable[_-]?oauth[_-]?client[_-]?secret",
    "gh[_-]?token", "gh[_-]?repo[_-]?token", "gh[_-]?oauth[_-]?token",
    "gh[_-]?oauth[_-]?client[_-]?secret",
    "gh[_-]?next[_-]?unstable[_-]?oauth[_-]?client[_-]?secret",
    "gh[_-]?next[_-]?unstable[_-]?oauth[_-]?client[_-]?id",
    "gh[_-]?next[_-]?oauth[_-]?client[_-]?secret",
    "gh[_-]?email", "gh[_-]?api[_-]?key",
    "gcs[_-]?bucket", "gcr[_-]?password",
    "gcloud[_-]?service[_-]?key", "gcloud[_-]?project", "gcloud[_-]?bucket",
    "ftp[_-]?username", "ftp[_-]?user", "ftp[_-]?pw", "ftp[_-]?password",
    "ftp[_-]?login", "ftp[_-]?host", "fossa[_-]?api[_-]?key",
    "flickr[_-]?api[_-]?secret", "flickr[_-]?api[_-]?key",
    "flask[_-]?secret[_-]?key", "firefox[_-]?secret",
    "firebase[_-]?token", "firebase[_-]?project[_-]?develop",
    "firebase[_-]?key", "firebase[_-]?api[_-]?token", "firebase[_-]?api[_-]?json",
    "file[_-]?password", "exp[_-]?password", "eureka[_-]?awssecretkey",
    "env[_-]?sonatype[_-]?password", "env[_-]?secret[_-]?access[_-]?key",
    "env[_-]?secret", "env[_-]?key",
    "env[_-]?heroku[_-]?api[_-]?key", "env[_-]?github[_-]?oauth[_-]?token",
    "end[_-]?user[_-]?password", "encryption[_-]?password",
    "elasticsearch[_-]?password", "elastic[_-]?cloud[_-]?auth",
    "dsonar[_-]?projectkey", "dsonar[_-]?login",
    "droplet[_-]?travis[_-]?password", "dropbox[_-]?oauth[_-]?bearer",
    "doordash[_-]?auth[_-]?token",
    "dockerhubpassword", "dockerhub[_-]?password",
    "docker[_-]?token", "docker[_-]?postgres[_-]?url",
    "docker[_-]?password", "docker[_-]?passwd", "docker[_-]?pass",
    "docker[_-]?key", "docker[_-]?hub[_-]?password",
    "digitalocean[_-]?ssh[_-]?key[_-]?ids",
    "digitalocean[_-]?ssh[_-]?key[_-]?body",
    "digitalocean[_-]?access[_-]?token", "dgpg[_-]?passphrase",
    "deploy[_-]?user", "deploy[_-]?token", "deploy[_-]?secure",
    "deploy[_-]?password",
    "ddgc[_-]?github[_-]?token", "ddg[_-]?test[_-]?email[_-]?pw",
    "ddg[_-]?test[_-]?email",
    "db[_-]?username", "db[_-]?user", "db[_-]?pw", "db[_-]?password",
    "db[_-]?host", "db[_-]?database", "db[_-]?connection",
    "datadog[_-]?app[_-]?key", "datadog[_-]?api[_-]?key",
    "database[_-]?username", "database[_-]?user", "database[_-]?port",
    "database[_-]?password", "database[_-]?name", "database[_-]?host",
    "danger[_-]?github[_-]?api[_-]?token", "cypress[_-]?record[_-]?key",
    "coverity[_-]?scan[_-]?token", "coveralls[_-]?token",
    "coveralls[_-]?repo[_-]?token", "coveralls[_-]?api[_-]?token",
    "cos[_-]?secrets",
    "conversation[_-]?username", "conversation[_-]?password",
    "contentful[_-]?v2[_-]?access[_-]?token",
    "contentful[_-]?test[_-]?org[_-]?cma[_-]?token",
    "contentful[_-]?php[_-]?management[_-]?test[_-]?token",
    "contentful[_-]?management[_-]?api[_-]?access[_-]?token[_-]?new",
    "contentful[_-]?management[_-]?api[_-]?access[_-]?token",
    "contentful[_-]?integration[_-]?management[_-]?token",
    "contentful[_-]?cma[_-]?test[_-]?token",
    "contentful[_-]?access[_-]?token",
    "consumerkey", "consumer[_-]?key", "conekta[_-]?apikey",
    "coding[_-]?token", "codecov[_-]?token", "codeclimate[_-]?repo[_-]?token",
    "codacy[_-]?project[_-]?token",
    "cocoapods[_-]?trunk[_-]?token", "cocoapods[_-]?trunk[_-]?email",
    "cn[_-]?secret[_-]?access[_-]?key", "cn[_-]?access[_-]?key[_-]?id",
    "clu[_-]?ssh[_-]?private[_-]?key[_-]?base64", "clu[_-]?repo[_-]?url",
    "cloudinary[_-]?url[_-]?staging", "cloudinary[_-]?url",
    "cloudflare[_-]?email", "cloudflare[_-]?auth[_-]?key",
    "cloudflare[_-]?auth[_-]?email", "cloudflare[_-]?api[_-]?key",
    "cloudant[_-]?service[_-]?database", "cloudant[_-]?processed[_-]?database",
    "cloudant[_-]?password", "cloudant[_-]?parsed[_-]?database",
    "cloudant[_-]?order[_-]?database", "cloudant[_-]?instance",
    "cloudant[_-]?database", "cloudant[_-]?audited[_-]?database",
    "cloudant[_-]?archived[_-]?database",
    "cloud[_-]?api[_-]?key", "clojars[_-]?password", "client[_-]?secret",
    "cli[_-]?e2e[_-]?cma[_-]?token",
    "claimr[_-]?token", "claimr[_-]?superuser", "claimr[_-]?db",
    "claimr[_-]?database",
    "ci[_-]?user[_-]?token", "ci[_-]?server[_-]?name",
    "ci[_-]?registry[_-]?user", "ci[_-]?project[_-]?url",
    "ci[_-]?deploy[_-]?password",
    "chrome[_-]?refresh[_-]?token", "chrome[_-]?client[_-]?secret",
    "cheverny[_-]?token", "cf[_-]?password", "certificate[_-]?password",
    "censys[_-]?secret",
    "cattle[_-]?secret[_-]?key", "cattle[_-]?agent[_-]?instance[_-]?auth",
    "cattle[_-]?access[_-]?key", "cargo[_-]?token",
    "cache[_-]?s3[_-]?secret[_-]?key",
    "bx[_-]?username", "bx[_-]?password",
    "bundlesize[_-]?github[_-]?token", "built[_-]?branch[_-]?deploy[_-]?key",
    "bucketeer[_-]?aws[_-]?secret[_-]?access[_-]?key",
    "bucketeer[_-]?aws[_-]?access[_-]?key[_-]?id",
    "browserstack[_-]?access[_-]?key", "browser[_-]?stack[_-]?access[_-]?key",
    "brackets[_-]?repo[_-]?oauth[_-]?token",
    "bluemix[_-]?username", "bluemix[_-]?pwd", "bluemix[_-]?password",
    "bluemix[_-]?pass[_-]?prod", "bluemix[_-]?pass",
    "bluemix[_-]?auth", "bluemix[_-]?api[_-]?key",
    "bintraykey", "bintray[_-]?token", "bintray[_-]?key",
    "bintray[_-]?gpg[_-]?password", "bintray[_-]?apikey", "bintray[_-]?api[_-]?key",
    "b2[_-]?bucket", "b2[_-]?app[_-]?key",
    "awssecretkey", "awscn[_-]?secret[_-]?access[_-]?key",
    "awscn[_-]?access[_-]?key[_-]?id", "awsaccesskeyid",
    "aws[_-]?ses[_-]?secret[_-]?access[_-]?key",
    "aws[_-]?ses[_-]?access[_-]?key[_-]?id", "aws[_-]?secrets",
    "aws[_-]?secret[_-]?key", "aws[_-]?secret[_-]?access[_-]?key",
    "aws[_-]?secret", "aws[_-]?key",
    "aws[_-]?config[_-]?secretaccesskey", "aws[_-]?config[_-]?accesskeyid",
    "aws[_-]?access[_-]?key[_-]?id", "aws[_-]?access[_-]?key", "aws[_-]?access",
    "author[_-]?npm[_-]?api[_-]?key", "author[_-]?email[_-]?addr",
    "auth0[_-]?client[_-]?secret", "auth0[_-]?api[_-]?clientsecret",
    "auth[_-]?token",
    "assistant[_-]?iam[_-]?apikey",
    "artifacts[_-]?secret", "artifacts[_-]?key", "artifacts[_-]?bucket",
    "artifacts[_-]?aws[_-]?secret[_-]?access[_-]?key",
    "artifacts[_-]?aws[_-]?access[_-]?key[_-]?id", "artifactory[_-]?key",
    "argos[_-]?token", "apple[_-]?id[_-]?password", "appclientsecret",
    "app[_-]?token", "app[_-]?secrete", "app[_-]?report[_-]?token[_-]?key",
    "app[_-]?bucket[_-]?perm",
    "apigw[_-]?access[_-]?token", "apiary[_-]?api[_-]?key",
    "api[_-]?secret", "api[_-]?key[_-]?sid", "api[_-]?key[_-]?secret",
    "api[_-]?key", "aos[_-]?sec", "aos[_-]?key",
    "ansible[_-]?vault[_-]?password", "android[_-]?docs[_-]?deploy[_-]?token",
    "anaconda[_-]?token",
    "amazon[_-]?secret[_-]?access[_-]?key", "amazon[_-]?bucket[_-]?name",
    "alicloud[_-]?secret[_-]?key", "alicloud[_-]?access[_-]?key",
    "alias[_-]?pass",
    "algolia[_-]?search[_-]?key[_-]?1", "algolia[_-]?search[_-]?key",
    "algolia[_-]?search[_-]?api[_-]?key",
    "algolia[_-]?api[_-]?key[_-]?search", "algolia[_-]?api[_-]?key[_-]?mcm",
    "algolia[_-]?api[_-]?key", "algolia[_-]?admin[_-]?key[_-]?mcm",
    "algolia[_-]?admin[_-]?key[_-]?2", "algolia[_-]?admin[_-]?key[_-]?1",
    "adzerk[_-]?api[_-]?key", "admin[_-]?email",
    "account[_-]?sid", "access[_-]?token", "access[_-]?secret",
    "access[_-]?key[_-]?secret",
    "account", "password", "username",
]

# 通配符型规则
_NUCLEI_WILDCARD_SOURCES = [
    r"""[\w_-]*?password[\w_-]*?""",
    r"""[\w_-]*?username[\w_-]*?""",
    r"""[\w_-]*?accesskey[\w_-]*?""",
    r"""[\w_-]*?secret[\w_-]*?""",
    r"""[\w_-]*?bucket[\w_-]*?""",
    r"""[\w_-]*?token[\w_-]*?""",
]

# 特殊格式的规则 (非 key=value 型)
_NUCLEI_SPECIAL_PATTERNS = [
    r"""[\"']?[-]+BEGIN \w+ PRIVATE KEY[-]+""",
    r"""[\"']?huawei\.oss\.(ak|sk|bucket\.name|endpoint|local\.path)[\"']?\s*[=:]\s*[\"']?[\w-]+[\"']?""",
    r"""[\"']?private[_-]?key(?:[_-]?id)?[\"']?\s*[=:]\s*[\"']?[\w-]+[\"']?""",
    r"""[\"']?account[_-]?(?:name|key)?[\"']?\s*[=:]\s*[\"']?[\w-]+[\"']?""",
    r"""LTAI[A-Za-z\d]{12,30}""",
    r"""AKID[A-Za-z\d]{13,40}""",
    r"""JDC_[0-9A-Z]{25,40}""",
    r"""[\"']?(?:A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}[\"']?""",
    r"""(?:AKLT|AKTP)[a-zA-Z0-9]{35,50}""",
    r"""AKLT[a-zA-Z0-9\-_]{16,28}""",
    r"""AIza[0-9A-Za-z_\-]{35}""",
    r"""[Bb]earer\s+[a-zA-Z0-9\-=._+/\\]{20,500}""",
    r"""[Bb]asic\s+[A-Za-z0-9+/]{18,}={0,2}""",
    r"""[\"'\[]*[Aa]uthorization[\"'\]]*\s*[:=]\s*['"]?\b(?:[Tt]oken\s+)?[a-zA-Z0-9\-_+/]{20,500}['"]?""",
    r"""(glpat-[a-zA-Z0-9\-=_]{20,22})""",
    r"""((?:ghp|gho|ghu|ghs|ghr|github_pat)_[a-zA-Z0-9_]{36,255})""",
    r"""APID[a-zA-Z0-9]{32,42}""",
    r"""[\"'](wx[a-z0-9]{15,18})[\"']""",
    r"""[\"'](ww[a-z0-9]{15,18})[\"']""",
    r"""[\"'](gh_[a-z0-9]{11,13})[\"']""",
    r"""(?:admin_?pass|password|[a-z]{3,15}_?password|user_?pass|user_?pwd|admin_?pwd)\\?['\"]*\s*[:=]\s*\\?['"][a-z0-9!@#$%&*]{5,20}\\?['"]""",
    r"""https:\/\/qyapi\.weixin\.qq\.com\/cgi\-bin\/webhook\/send\?key=[a-zA-Z0-9\-]{25,50}""",
    r"""https:\/\/oapi\.dingtalk\.com\/robot\/send\?access_token=[a-z0-9]{50,80}""",
    r"""https:\/\/open\.feishu\.cn\/open\-apis\/bot\/v2\/hook\/[a-z0-9\-]{25,50}""",
    r"""https:\/\/hooks\.slack\.com\/services\/[a-zA-Z0-9\-_]{6,12}\/[a-zA-Z0-9\-_]{6,12}\/[a-zA-Z0-9\-_]{15,24}""",
    r"""eyJrIjoi[a-zA-Z0-9\-_+/]{50,100}={0,2}""",
    r"""glc_[A-Za-z0-9\-_+/]{32,200}={0,2}""",
    r"""glsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8}""",
    r"""[\"']?air[-_]?table[-_]?api[-_]?key[\"']?[=:][\"']?.+[\"']""",
    r"""[\"']?jdbc:mysql[\"']?\s*[=:]\s*[\"']?[\w-]+[\"']?""",
]


def _build_nuclei_patterns() -> List[re.Pattern]:
    """编译所有nuclei正则为Python Pattern对象 (与heartk_fast.py完全一致)"""
    compiled = []
    all_kv_keys = list(_NUCLEI_REGEX_SOURCES) + list(_NUCLEI_WILDCARD_SOURCES)
    batch_size = 120
    for i in range(0, len(all_kv_keys), batch_size):
        batch = all_kv_keys[i:i + batch_size]
        alternation = '|'.join(batch)
        pat = r"""[\"']?(?:""" + alternation + r""")[\"']?[^\S\r\n]*[=:][^\S\r\n]*[\"']?[\w-]+[\"']?"""
        compiled.append(re.compile(pat, re.IGNORECASE))

    for pat_str in _NUCLEI_SPECIAL_PATTERNS:
        try:
            compiled.append(re.compile(pat_str, re.IGNORECASE))
        except re.error:
            compiled.append(re.compile(pat_str))

    return compiled


NUCLEI_PATTERNS = _build_nuclei_patterns()


# ============================================================
# 2. 核心分析函数 (与 heartk_fast.py 完全一致)
# ============================================================

def strip_quotes(items: List[str]) -> List[str]:
    """移除字符串两端的引号"""
    result = []
    for item in items:
        s = 0
        e = len(item)
        if item and item[0] in ("'", '"'):
            s = 1
        if item and item[-1] in ("'", '"'):
            e -= 1
        result.append(item[s:e])
    return result


def extract_info(data: str) -> Dict[str, Optional[List[str]]]:
    """从文本内容中提取各类敏感信息 (对应JS中的 extract_info + get_secret)"""
    result: Dict[str, Optional[List[str]]] = {}

    # 运行各分类正则
    for key, pattern in EXTRACT_PATTERNS.items():
        matches = pattern.findall(data)
        if matches:
            # findall 对于有组的正则返回元组，取第一个完整匹配或全匹配
            if isinstance(matches[0], tuple):
                # 需要完整匹配，用 finditer
                matches = [m.group(0) for m in pattern.finditer(data)]
            result[key] = matches if matches else None
        else:
            result[key] = None

    # 从URL中额外提取IP/域名 (对应JS中 extract_info 末尾逻辑)
    if result.get('url'):
        ip_pat = re.compile(r"""['\"](([a-zA-Z0-9]+:)?\/\/)?\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}""")
        for url in result['url']:
            ip_matches = ip_pat.findall(url)
            if ip_matches:
                full_matches = [m.group(0) for m in ip_pat.finditer(url)]
                if result['ip'] is None:
                    result['ip'] = full_matches
                else:
                    result['ip'].extend(full_matches)

    # 运行nuclei秘密检测
    secrets = []
    for pat in NUCLEI_PATTERNS:
        try:
            matches = pat.findall(data)
            if matches:
                if isinstance(matches[0], tuple):
                    for m in pat.finditer(data):
                        secrets.append(m.group(0))
                else:
                    secrets.extend(matches)
        except Exception:
            pass
    result['secret'] = secrets if secrets else None

    return result


def init_source(source: str) -> List[str]:
    """从HTML中提取href和src属性值 (对应JS中的 init_source)"""
    target_list = []

    # href="..."
    for m in re.finditer(r"""href=['\"](.+?)['\"]""", source):
        target_list.append(m.group(1))

    # src="..."
    for m in re.finditer(r"""src=['\"](.+?)['\"]""", source):
        target_list.append(m.group(1))

    return list(set(target_list))


def collect_static(items: List[str], static_list: List[str]) -> tuple:
    """分离静态资源"""
    remaining = []
    for item in items:
        is_static = False
        for ext in STATIC_EXTENSIONS:
            if ext in item:
                if ext == '.js' and '.jsp' in item:
                    continue
                is_static = True
                if item not in static_list:
                    static_list.append(item)
                break
        if not is_static:
            remaining.append(item)
    return remaining, static_list


def get_info(content: str) -> Dict[str, Optional[List[str]]]:
    """完整分析一个文件内容"""
    tmp_data = extract_info(content)

    source_links = init_source(content)
    static_data: List[str] = []

    if source_links:
        _, static_data = collect_static(source_links, static_data)

    for key in ['domain', 'path', 'url']:
        if tmp_data.get(key):
            _, static_data = collect_static(tmp_data[key], static_data)

    for key in ['domain', 'path', 'url']:
        if tmp_data.get(key):
            tmp_data[key], _ = collect_static(tmp_data[key], list(static_data))

    tmp_data['static'] = static_data if static_data else None

    # 去引号 (secret 保留原始)
    not_sub_keys = {'secret'}
    for key in CATEGORIES:
        if key in tmp_data and tmp_data[key] is not None and key not in not_sub_keys:
            tmp_data[key] = strip_quotes(tmp_data[key])

    return tmp_data


# ============================================================
# 3. 文件扫描
# ============================================================

def detect_encoding(filepath: str) -> Optional[str]:
    """检测文件编码"""
    if chardet is None:
        return "utf-8"
    try:
        with open(filepath, 'rb') as f:
            raw = f.read(65536)
            if not raw:
                return None
            result = chardet.detect(raw)
            return result.get('encoding')
    except Exception:
        return None


def scan_single_file(filepath: str) -> Optional[Dict[str, Optional[List[str]]]]:
    """扫描单个文件，返回分析结果"""
    encoding = detect_encoding(filepath)
    if not encoding:
        return None

    try:
        with open(filepath, 'r', encoding=encoding, errors='ignore') as f:
            content = f.read()
        if not content.strip():
            return None
        return get_info(content)
    except Exception:
        return None


def scan_single_file_with_custom(args):
    """带自定义正则的扫描 (用于进程池)"""
    filepath, custom_patterns_raw = args

    # 基础扫描
    result = scan_single_file(filepath)
    if result is None:
        result = {}

    # 自定义正则扫描
    if custom_patterns_raw:
        encoding = detect_encoding(filepath)
        if not encoding:
            return filepath, result if result else None
        try:
            with open(filepath, 'r', encoding=encoding, errors='ignore') as f:
                content = f.read()
        except Exception:
            return filepath, result if result else None

        if content.strip():
            for name, pat_str in custom_patterns_raw.items():
                try:
                    pat = re.compile(pat_str, re.IGNORECASE)
                    matches = [m.group(0) for m in pat.finditer(content)]
                    if matches:
                        result[f"custom_{name}"] = matches
                except Exception:
                    pass

    return filepath, result if result else None


_SCAN_EXTS = {'.js', '.html', '.htm', '.json', '.css', '.wxml', '.wxss', '.txt', '.xml', '.svg', '.ts', '.jsx', '.tsx', '.md', '.yaml', '.yml', '.cfg', '.ini', '.conf', '.env', '.properties'}


def collect_files(path: str) -> List[str]:
    """递归收集所有可扫描的文本文件"""
    files = []
    for root, dirs, filenames in os.walk(path):
        for fn in filenames:
            ext = os.path.splitext(fn)[1].lower()
            if ext in _SCAN_EXTS:
                files.append(os.path.join(root, fn))
    return files


def merge_results(all_info: Dict, file_result: Dict):
    """合并单文件结果到总结果"""
    for key, value in file_result.items():
        if value is None:
            continue
        if all_info.get(key) is None:
            all_info[key] = list(value)
        else:
            all_info[key].extend(value)


def dedup_and_sort(all_info: Dict):
    """去重并排序"""
    for key in list(all_info.keys()):
        if all_info.get(key) and isinstance(all_info[key], list):
            all_info[key] = sorted(set(all_info[key]))


# ============================================================
# 4. Extractor 类 (GUI 接口)
# ============================================================

class Extractor:
    """敏感信息提取引擎 — GUI 接口"""

    def __init__(self):
        self.custom_patterns: Dict[str, str] = {}  # {名称: 正则}

    def add_custom_pattern(self, name: str, regex_str: str):
        self.custom_patterns[name] = regex_str

    def remove_custom_pattern(self, name: str):
        self.custom_patterns.pop(name, None)

    def scan_directory(self, path: str, num_workers: int = 0,
                       on_progress: Optional[Callable] = None) -> Dict[str, Any]:
        """扫描目录，返回合并后的结果"""
        files = collect_files(path)
        if not files:
            return {"files_scanned": 0, "elapsed": 0, "results": {k: [] for k in CATEGORIES},
                    "custom_results": {}}

        if num_workers <= 0:
            num_workers = min(os.cpu_count() or 4, len(files))
        num_workers = max(1, min(num_workers, 16))

        all_info: Dict[str, Optional[List[str]]] = {k: None for k in CATEGORIES}
        custom_results: Dict[str, List[str]] = {}  # 自定义正则结果
        done_count = 0
        total = len(files)

        start_time = time.time()

        custom_raw = dict(self.custom_patterns) if self.custom_patterns else {}

        if num_workers == 1 or total <= 3:
            for fpath in files:
                _, result = scan_single_file_with_custom((fpath, custom_raw))
                done_count += 1
                if result:
                    # 分离自定义结果
                    for key in list(result.keys()):
                        if key.startswith("custom_"):
                            cat_name = key[7:]  # 去掉 "custom_" 前缀
                            if cat_name not in custom_results:
                                custom_results[cat_name] = []
                            custom_results[cat_name].extend(result.pop(key))
                    merge_results(all_info, result)
                if on_progress:
                    on_progress(done_count, total)
        else:
            args_list = [(f, custom_raw) for f in files]
            with ProcessPoolExecutor(max_workers=num_workers) as executor:
                future_to_file = {executor.submit(scan_single_file_with_custom, a): a[0] for a in args_list}
                for future in as_completed(future_to_file):
                    done_count += 1
                    try:
                        fpath, result = future.result()
                        if result:
                            for key in list(result.keys()):
                                if key.startswith("custom_"):
                                    cat_name = key[7:]
                                    if cat_name not in custom_results:
                                        custom_results[cat_name] = []
                                    custom_results[cat_name].extend(result.pop(key))
                            merge_results(all_info, result)
                    except Exception:
                        pass
                    if on_progress:
                        on_progress(done_count, total)

        # domain 合并到 url
        if all_info.get('domain'):
            if all_info.get('url'):
                all_info['url'].extend(all_info['domain'])
            else:
                all_info['url'] = list(all_info['domain'])

        # 去重排序
        dedup_and_sort(all_info)
        for k in custom_results:
            custom_results[k] = sorted(set(custom_results[k]))

        elapsed = time.time() - start_time

        return {
            "files_scanned": total,
            "elapsed": round(elapsed, 2),
            "results": {k: all_info.get(k) or [] for k in CATEGORIES},
            "custom_results": custom_results,
        }

    @staticmethod
    def export_json(scan_result: Dict, output_path: str):
        """导出 JSON (包含自定义正则结果)"""
        clean = {}
        for key in CATEGORIES:
            clean[key] = scan_result.get("results", {}).get(key, [])
        # 自定义正则结果
        for name, items in scan_result.get("custom_results", {}).items():
            clean[name] = items
        clean["_meta"] = {
            "files_scanned": scan_result.get("files_scanned", 0),
            "elapsed": scan_result.get("elapsed", 0),
        }
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(clean, f, ensure_ascii=False, indent=2)

    @staticmethod
    def export_html(scan_result: Dict, output_path: str):
        """生成 HTML 报告 (包含自定义正则结果)"""
        data = dict(scan_result.get("results", {}))
        custom = scan_result.get("custom_results", {})
        # 合并自定义到 data 以供 JS 使用
        for name, items in custom.items():
            data[name] = items

        data_json = json.dumps(data, ensure_ascii=False)

        # 所有类别 key 列表 (用于 JS)
        all_keys = list(CATEGORIES) + list(custom.keys())
        keys_js = json.dumps(all_keys, ensure_ascii=False)

        popup_js = r"""
    var key = """ + keys_js + r""";
    let messages = {"popupCopy": "复制", "popupCopyurl": "复制URL"};
    function getMessage(key) { return messages[key] || ""; }
    function init_copy() {
        var elements = document.getElementsByClassName("copy");
        if(elements){
            for (var i=0, len=elements.length|0; i<len; i=i+1|0) {
                elements[i].textContent = getMessage("popupCopy");
                let ele_name = elements[i].name;
                let ele_id = elements[i].id;
                if (ele_id == "popupCopyurl") elements[i].textContent = getMessage("popupCopyurl");
                elements[i].onclick=function () {
                    var inp = document.createElement('textarea');
                    document.body.appendChild(inp);
                    var copytext = document.getElementById(ele_name).textContent;
                    inp.value = copytext; inp.select();
                    document.execCommand('copy',false); inp.remove();
                }
            }
        }
    }
    function show_info(result_data) {
        for (var k in key){
            if (result_data[key[k]]){
                let container = document.getElementById(key[k]);
                if (!container) continue;
                while((ele = container.firstChild)) ele.remove();
                container.style.whiteSpace = "pre";
                for (var i in result_data[key[k]]){
                    let tips = document.createElement("div");
                    tips.setAttribute("class", "tips");
                    let link = document.createElement("a");
                    link.appendChild(tips);
                    let span = document.createElement("span");
                    span.textContent = result_data[key[k]][i]+'\n';
                    container.appendChild(link);
                    container.appendChild(span);
                }
            }
        }
    }
    init_copy();
    show_info(""" + data_json + ')'

        cat_labels = {
            'ip': 'IP', 'ip_port': 'IP:PORT', 'domain': '域名',
            'sfz': '身份证', 'mobile': '手机号', 'mail': '邮箱',
            'jwt': 'JWT', 'algorithm': '加密算法', 'secret': 'Secret/密钥',
            'path': 'Path', 'incomplete_path': 'IncompletePath',
            'url': 'URL', 'static': 'StaticUrl'
        }
        left_cats = ['ip', 'ip_port', 'domain', 'sfz', 'mobile', 'mail', 'jwt', 'algorithm', 'secret']
        right_cats = ['path', 'incomplete_path', 'url', 'static']

        left_html = ""
        for cat in left_cats:
            label = cat_labels.get(cat, cat)
            count = len(data.get(cat, []))
            left_html += f'<div class="cat_title">{label} ({count})</div><button class="copy" name="{cat}">复制</button>\n<p id="{cat}" style="word-break:break-word;">🈚️</p>\n'

        right_html = ""
        for cat in right_cats:
            label = cat_labels.get(cat, cat)
            count = len(data.get(cat, []))
            right_html += f'<div class="cat_title">{label} ({count})</div><button class="copy" name="{cat}">复制</button>\n<p id="{cat}">🈚️</p>\n'

        # 自定义正则类别
        custom_html = ""
        for name, items in custom.items():
            count = len(items)
            custom_html += f'<div class="cat_title">{name} ({count})</div><button class="copy" name="{name}">复制</button>\n<p id="{name}" style="word-break:break-word;">🈚️</p>\n'

        meta = scan_result.get("files_scanned", 0)
        elapsed = scan_result.get("elapsed", 0)
        total_findings = sum(len(data.get(k, [])) for k in all_keys)

        report_html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="UTF-8"><title>敏感信息提取报告</title></head>
<body style="width:860px; font-size: 14px; font-family: 'Microsoft YaHei', sans-serif; margin: 20px auto;">
    <div style="margin-bottom: 16px;">
        <div style="display:inline-block; padding:6px 16px; background:#000; color:#fff; border-radius:4px; font-weight:bold;">
            First 敏感信息提取报告
        </div>
    </div>
    <div style="display:flex; gap:16px;">
        <div style="flex:1; border-right:1px solid #e8e8e8; padding-right:16px;">
            {left_html}
        </div>
        <div style="flex:1.5;">
            {right_html}
        </div>
    </div>
    {"<div style='margin-top:16px; border-top:1px solid #e8e8e8; padding-top:12px;'><div class='cat_title' style='margin-bottom:8px;'>自定义规则结果</div>" + custom_html + "</div>" if custom_html else ""}
<script>
{popup_js}
</script>
<style>
    .copy {{ border:none; background:#fff; float:right; cursor:pointer; color:#16a34a; }}
    .cat_title {{ font-size:15px; font-weight:bold; border-left:4px solid #16a34a; padding-left:6px; margin-top:12px; }}
    .tips {{ display:inline-block; border-top:0.2px solid; border-right:0.2px solid; width:8px; height:8px; border-color:#EA6000; transform:rotate(-135deg); }}
    a {{ text-decoration:none; color:#333; }}
    p {{ word-break:break-all; white-space:pre-wrap; font-size:13px; }}
</style>
</html>"""
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(report_html)

    @staticmethod
    def get_summary(scan_result: Dict) -> Dict[str, int]:
        """返回各分类的计数 (含自定义)"""
        summary = {}
        results = scan_result.get("results", {})
        for key in CATEGORIES:
            summary[key] = len(results.get(key, []))
        for name, items in scan_result.get("custom_results", {}).items():
            summary[name] = len(items)
        return summary

    @staticmethod
    def get_category_label(key: str) -> str:
        labels = {
            'sfz': '身份证', 'mobile': '手机号', 'mail': '邮箱',
            'ip': 'IP地址', 'ip_port': 'IP端口', 'domain': '域名',
            'path': '路径', 'incomplete_path': '不完整路径',
            'url': 'URL', 'jwt': 'JWT', 'algorithm': '加密算法',
            'secret': '密钥/凭证', 'static': '静态资源'
        }
        return labels.get(key, key)

    @staticmethod
    def get_all_builtin_patterns() -> Dict[str, str]:
        """获取所有内置正则的字符串表示 (供 UI 显示)"""
        result = {}
        # extract patterns
        for key, pat in EXTRACT_PATTERNS.items():
            result[f"[提取] {key}"] = pat.pattern
        # nuclei kv keys count
        result["[密钥] key=value 关键字"] = f"({len(_NUCLEI_REGEX_SOURCES)} 个关键字匹配)"
        # nuclei wildcards
        for i, pat in enumerate(_NUCLEI_WILDCARD_SOURCES):
            result[f"[密钥] 通配符 #{i+1}"] = pat
        # nuclei specials
        for i, pat in enumerate(_NUCLEI_SPECIAL_PATTERNS):
            result[f"[密钥] 特殊规则 #{i+1}"] = pat
        return result
