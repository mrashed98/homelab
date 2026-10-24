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
# TradeLine (Shopify) rate-limits our IP hard and 429s count against the limit, so it gets its own slow
# schedule: one product per SHOPIFY_INTERVAL (round-robin), doubling backoff on 429 up to an hour.
SHOPIFY_INTERVAL = int(os.environ.get("SHOPIFY_INTERVAL_SECONDS", "300"))
BACKOFF_MIN, BACKOFF_MAX = 600, 3600
# Alert that the tracker is blind once a store has had no successful read for this long
STALE = {"eshop.orange.eg": INTERVAL * 20}
SHOPIFY_STALE = 3 * 3600
# In-stock alerts are re-posted every poll of that product; they must outlive the gap or they flap on Telegram
SHOPIFY_ALERT_TTL = SHOPIFY_INTERVAL * max(len(SHOPIFY_PRODUCTS), 1) * 2 + BACKOFF_MAX
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


def alert(name, severity, summary, description, extra_labels=None, ttl=None):
    # endsAt in the near future: keeps firing while we re-post every poll, auto-resolves once we stop
    ends = (datetime.now(timezone.utc) + timedelta(seconds=ttl or max(INTERVAL * 4, 120))).isoformat()
    return {"labels": {"alertname": name, "severity": severity, "namespace": NAMESPACE, **(extra_labels or {})},
            "annotations": {"summary": summary, "description": description}, "endsAt": ends}


def build_alerts(store, items, ttl=None):
    return [alert("iPhoneInStock", "critical", summary, f"Price: EGP {price:,.0f}\n{url}",
                  {"store": store, "variant": variant}, ttl)
            for variant, summary, price, url in items]


class Shopify:
    """Round-robin over SHOPIFY_PRODUCTS, one request when due, backing off on 429."""

    def __init__(self, urls):
        self.urls, self.i, self.due, self.backoff = urls, 0, 0.0, 0

    def poll(self, now):
        """-> (store, url, fetch-and-parse fn) when a request is due, else None"""
        if not self.urls or now < self.due:
            return None
        u = self.urls[self.i % len(self.urls)]
        return urlparse(u).hostname, u, lambda: shopify_items(get_json(u.rstrip("/") + ".js"), u)

    def done(self, now, err=None):
        if isinstance(err, urllib.error.HTTPError) and err.code == 429:
            self.backoff = min(max(self.backoff * 2, BACKOFF_MIN), BACKOFF_MAX)
            self.due = now + self.backoff  # retry the same product
        else:
            self.backoff = 0
            self.i += err is None  # move on only after a good read, so no colour gets skipped
            self.due = now + SHOPIFY_INTERVAL


def post(alerts):
    req = urllib.request.Request(f"{ALERTMANAGER}/api/v2/alerts", data=json.dumps(alerts).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def main():
    dry = "--dry-run" in sys.argv
    shop = Shopify(SHOPIFY_PRODUCTS)
    last_ok = {}  # store -> monotonic time of last successful read
    started = time.monotonic()
    while True:
        alerts, now = [], time.monotonic()
        polls = [("eshop.orange.eg", API, lambda: orange_items(get_json(API, **{"Accept-Language": "en-US"})["Data"]), None)]
        if p := shop.poll(now):
            polls.append((*p, shop))
        for store, url, check, sched in polls:
            err = None
            try:
                items = check()
                last_ok[store] = now
                print(f"{datetime.now():%H:%M:%S} {store} {url.rsplit('/', 1)[-1]} available={[i[0] for i in items]}", flush=True)
                alerts += build_alerts(store, items, sched and SHOPIFY_ALERT_TTL)
            except Exception as e:  # never die on a bad poll; the API or network will hiccup
                err = e
                print(f"{datetime.now():%H:%M:%S} {store} poll failed: {e!r}", flush=True)
            if sched:
                sched.done(now, err)
        for store in {"eshop.orange.eg", *(urlparse(u).hostname for u in SHOPIFY_PRODUCTS)}:
            blind = now - last_ok.get(store, started)
            if blind > STALE.get(store, SHOPIFY_STALE):
                alerts.append(alert("iPhoneTrackerFailing", "warning", f"iPhone stock tracker cannot read {store}",
                                    f"No successful read for {blind / 60:.0f} min (see pod logs)", {"store": store}))
        if alerts:
            try:
                print(json.dumps(alerts, ensure_ascii=False)) if dry else post(alerts)
            except Exception as e:
                print(f"alertmanager post failed: {e!r}", flush=True)
        if dry:
            return
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

    sh = Shopify(["https://t.com/products/a", "https://t.com/products/b"])
    assert sh.poll(0)[1].endswith("/a")
    sh.done(0)
    assert sh.poll(SHOPIFY_INTERVAL - 1) is None and sh.poll(SHOPIFY_INTERVAL)[1].endswith("/b")
    e429 = urllib.error.HTTPError("u", 429, "", {}, None)
    sh.done(1000, e429)
    sh.done(1000, e429)
    assert sh.backoff == 2 * BACKOFF_MIN and sh.poll(1000 + 2 * BACKOFF_MIN)[1].endswith("/b")  # same product retried
    for _ in range(10):
        sh.done(1000, e429)
    assert sh.backoff == BACKOFF_MAX
    sh.done(1000)
    assert sh.backoff == 0 and sh.poll(1000 + SHOPIFY_INTERVAL)[1].endswith("/a")
    print("ok")


if __name__ == "__main__":
    _test() if "--test" in sys.argv else main()
