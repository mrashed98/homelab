"""Polls Orange EG eShop + Shopify stores for stock and fires an Alertmanager alert (-> Homealert Telegram) per in-stock item."""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse

SE_NAME = os.environ.get("SE_NAME", "iphone-18-pro-max")
API = f"https://eshop.orange.eg/api/CatalogAPI/Products/GetProductDetails?seName={SE_NAME}"
PAGE = f"https://eshop.orange.eg/ar/smart-phones/p/{SE_NAME}"
# Shopify product page URLs, comma-separated; each exposes public stock at <url>.js
SHOPIFY_PRODUCTS = [u.strip() for u in os.environ.get("SHOPIFY_PRODUCTS", "").split(",") if u.strip()]
ALERTMANAGER = os.environ.get("ALERTMANAGER_URL", "http://prometheus-alertmanager.monitoring:9093")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "30"))
FAIL_ALERT_AFTER = 20  # consecutive failed polls of one URL before alerting that the tracker is blind
# Shopify 429s when every product is fetched each poll, so one product per poll, round-robin
ROTATION = max(len(SHOPIFY_PRODUCTS), 1)
NAMESPACE = os.environ.get("POD_NAMESPACE", "iphone-tracker")


def get_json(url, **headers):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", **headers})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def available_variants(d):
    names = {v["Id"]: v["Name"].strip() for a in d["Attributes"] for v in a["Values"]}
    out = [(" / ".join(names.get(a["AttributeValueId"], "?") for a in c["AttributeValues"]), c["Price"]["Amount"])
           for c in d["Combinations"] if c.get("IsAvailable")]
    # Product-level flags can flip without a per-variant one (e.g. pre-order opening)
    if not out and (d.get("InStock") or d.get("AvailableForPreOrder") or d.get("IsAvailableForPreorderWithPayment")):
        out = [("pre-order" if not d.get("InStock") else "any", d["Price"]["Amount"])]
    return out


def orange_items(d):
    """-> [(variant label, summary, price, url)]"""
    return [(v, f"{d['Name']} {v} is available on Orange eShop", price, PAGE) for v, price in available_variants(d)]


def shopify_items(d, url):
    store = urlparse(url).hostname
    out = []
    for v in d["variants"]:
        if v.get("available"):
            name = d["title"] if v["title"] == "Default Title" else f"{d['title']} {v['title']}"
            out.append((name, f"{name} is available on {store}", v["price"] / 100, url))
    return out


def alert(name, severity, summary, description, extra_labels=None):
    # endsAt in the near future: keeps firing while we re-post every poll, auto-resolves once we stop
    # must outlive a full rotation, or an in-stock alert resolves and re-fires between its polls
    ends = (datetime.now(timezone.utc) + timedelta(seconds=max(INTERVAL * ROTATION * 2, 120))).isoformat()
    return {"labels": {"alertname": name, "severity": severity, "namespace": NAMESPACE, **(extra_labels or {})},
            "annotations": {"summary": summary, "description": description}, "endsAt": ends}


def build_alerts(store, items):
    return [alert("iPhoneInStock", "critical", summary, f"Price: EGP {price:,.0f}\n{url}",
                  {"store": store, "variant": variant})
            for variant, summary, price, url in items]


def sources(n):
    """-> [(store, url for errors, fetch-and-parse fn)] for poll number n"""
    yield "eshop.orange.eg", API, lambda: orange_items(get_json(API, **{"Accept-Language": "en-US"})["Data"])
    for u in SHOPIFY_PRODUCTS[n % ROTATION:][:1]:
        yield urlparse(u).hostname, u, lambda u=u: shopify_items(get_json(u.rstrip("/") + ".js"), u)


def post(alerts):
    req = urllib.request.Request(f"{ALERTMANAGER}/api/v2/alerts", data=json.dumps(alerts).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def main():
    dry = "--dry-run" in sys.argv
    fails = {}  # per source url, so one dead store doesn't hide the others
    cooldown = {}  # store -> monotonic time until which we don't poll it (after a 429)
    n = 0
    while True:
        alerts = []
        for store, url, check in sources(n):
            if time.monotonic() < cooldown.get(store, 0):
                continue
            try:
                items = check()
                fails[url] = 0
                print(f"{datetime.now():%H:%M:%S} {store} {url.rsplit('/', 1)[-1]} available={[i[0] for i in items]}", flush=True)
                alerts += build_alerts(store, items)
            except Exception as e:  # never die on a bad poll; the API or network will hiccup
                if isinstance(e, urllib.error.HTTPError) and e.code == 429:
                    retry = e.headers.get("Retry-After", "")
                    # Shopify says 60s, but retrying that soon keeps the per-IP bucket full; 5 min floor
                    cooldown[store] = time.monotonic() + max(int(retry) if retry.isdigit() else 0, 300)
                fails[url] = fails.get(url, 0) + 1
                print(f"{datetime.now():%H:%M:%S} {store} poll failed ({fails[url]}): {e!r}", flush=True)
                if fails[url] >= FAIL_ALERT_AFTER:
                    alerts.append(alert("iPhoneTrackerFailing", "warning", f"iPhone stock tracker cannot read {store}",
                                        f"{fails[url]} consecutive failed polls. Last error: {e!r}\n{url}",
                                        {"store": store, "variant": url.rsplit("/", 1)[-1]}))
        if alerts:
            try:
                print(json.dumps(alerts, ensure_ascii=False)) if dry else post(alerts)
            except Exception as e:
                print(f"alertmanager post failed: {e!r}", flush=True)
        if dry:
            return
        n += 1
        time.sleep(INTERVAL)


def _test():
    d = {"Name": "iPhone", "InStock": True, "Price": {"Amount": 1.0},
         "Attributes": [{"Values": [{"Id": 1, "Name": "Black"}, {"Id": 2, "Name": "256GB"}]}],
         "Combinations": [{"AttributeValues": [{"AttributeValueId": 1}, {"AttributeValueId": 2}],
                           "Price": {"Amount": 111799.0}, "IsAvailable": True},
                          {"AttributeValues": [{"AttributeValueId": 1}], "Price": {"Amount": 5.0}, "IsAvailable": False}]}
    a = build_alerts("orange", orange_items(d))
    assert [x["labels"]["variant"] for x in a] == ["Black / 256GB"], a
    assert "111,799" in a[0]["annotations"]["description"]
    for c in d["Combinations"]:
        c["IsAvailable"] = False
    assert [x["labels"]["variant"] for x in build_alerts("o", orange_items(d))] == ["any"]
    d["InStock"] = False
    assert orange_items(d) == []
    d["AvailableForPreOrder"] = True
    assert [i[0] for i in orange_items(d)] == ["pre-order"]

    s = {"title": "iPhone 18 Pro Max 256GB Black", "variants": [
        {"title": "Default Title", "available": True, "price": 11179900},
        {"title": "1TB", "available": False, "price": 1}]}
    a = build_alerts("tradelinestores.com", shopify_items(s, "https://tradelinestores.com/products/x"))
    assert [x["labels"]["variant"] for x in a] == ["iPhone 18 Pro Max 256GB Black"], a
    assert "111,799" in a[0]["annotations"]["description"] and a[0]["labels"]["store"] == "tradelinestores.com"
    s["variants"][0]["available"] = False
    assert shopify_items(s, "u") == []
    assert len(list(sources(0))) == 1 + bool(SHOPIFY_PRODUCTS)  # orange + at most one shopify product per poll
    print("ok")


if __name__ == "__main__":
    _test() if "--test" in sys.argv else main()
