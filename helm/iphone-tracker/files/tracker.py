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
# Shopify product page URLs, comma-separated. Read via the tokenless Storefront GraphQL API, one request per
# store for all products: the storefront's /products/<handle>.js is behind bot protection and 429s us.
SHOPIFY_PRODUCTS = [u.strip() for u in os.environ.get("SHOPIFY_PRODUCTS", "").split(",") if u.strip()]
STOREFRONT_API_VERSION = "2025-07"
ALERTMANAGER = os.environ.get("ALERTMANAGER_URL", "http://prometheus-alertmanager.monitoring:9093")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "30"))
SHOPIFY_INTERVAL = int(os.environ.get("SHOPIFY_INTERVAL_SECONDS", "60"))
BACKOFF_MAX = 3600  # on 429/430: wait Retry-After (min 60s), doubling per repeat, up to this
STALE_POLLS = 20  # alert that the tracker is blind once a source has gone this many intervals without a good read
NAMESPACE = os.environ.get("POD_NAMESPACE", "iphone-tracker")


def fetch_json(url, body=None, **headers):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={
        "User-Agent": "Mozilla/5.0", "Accept": "application/json",
        **({"Content-Type": "application/json"} if data else {}), **headers})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def available_variants(d):
    names = {v["Id"]: v["Name"].replace("\u200f", "").strip() for a in d["Attributes"] for v in a["Values"]}
    out = [(" / ".join(names.get(a["AttributeValueId"], "?") for a in c["AttributeValues"]), c["Price"]["Amount"])
           for c in d["Combinations"] if c.get("IsAvailable")]
    # Product-level flags can flip without a per-variant one (e.g. pre-order opening)
    if not out and (d.get("InStock") or d.get("AvailableForPreOrder") or d.get("IsAvailableForPreorderWithPayment")):
        out = [("pre-order" if not d.get("InStock") else "any", d["Price"]["Amount"])]
    return out


def orange_items(d):
    """-> [(variant label, summary, price, url)]"""
    return [(v, f"{d['Name']} {v} is available on Orange eShop", price, PAGE) for v, price in available_variants(d)]


def storefront_query(handles):
    fields = "title variants(first: 20) { nodes { title availableForSale price { amount } } }"
    return "{ " + " ".join(f'p{i}: product(handle: {json.dumps(h)}) {{ {fields} }}' for i, h in enumerate(handles)) + " }"


def shopify_items(resp, urls):
    """Storefront API response for storefront_query(handles of urls) -> [(variant label, summary, price, url)]"""
    if resp.get("errors"):
        raise RuntimeError(f"storefront API errors: {resp['errors']}")
    out = []
    for i, url in enumerate(urls):
        p = resp["data"][f"p{i}"]
        if p is None:  # handle renamed/removed: fail loudly instead of silently never alerting
            raise LookupError(f"product not found: {url}")
        for v in p["variants"]["nodes"]:
            if v["availableForSale"]:
                name = p["title"] if v["title"] == "Default Title" else f"{p['title']} {v['title']}"
                out.append((name, f"{name} is available on {urlparse(url).hostname}", float(v["price"]["amount"]), url))
    return out


def shopify_fetcher(host, urls):
    handles = [urlparse(u).path.rstrip("/").rsplit("/", 1)[-1] for u in urls]
    api = f"https://{host}/api/{STOREFRONT_API_VERSION}/graphql.json"
    return lambda: shopify_items(fetch_json(api, {"query": storefront_query(handles)}), urls)


class Source:
    def __init__(self, store, url, fetch, interval):
        self.store, self.url, self.fetch, self.interval = store, url, fetch, interval
        self.due = self.backoff = 0
        self.last_ok = time.monotonic()

    def done(self, now, err=None):
        if isinstance(err, urllib.error.HTTPError) and err.code in (429, 430):
            retry = err.headers.get("Retry-After", "") if err.headers else ""
            self.backoff = min(max(self.backoff * 2, int(retry) if retry.isdigit() else 0, 60), BACKOFF_MAX)
            self.due = now + self.backoff
            return
        self.backoff = 0
        self.due = now + self.interval
        if err is None:
            self.last_ok = now

    def stale(self, now):
        return now - self.last_ok > self.interval * STALE_POLLS


def sources():
    out = [Source("eshop.orange.eg", API, lambda: orange_items(fetch_json(API, **{"Accept-Language": "en-US"})["Data"]),
                  INTERVAL)]
    by_host = {}
    for u in SHOPIFY_PRODUCTS:
        by_host.setdefault(urlparse(u).hostname, []).append(u)
    out += [Source(h, f"https://{h}/api/{STOREFRONT_API_VERSION}/graphql.json", shopify_fetcher(h, us), SHOPIFY_INTERVAL)
            for h, us in by_host.items()]
    return out


def alert(name, severity, summary, description, extra_labels=None, ttl=120):
    # endsAt in the near future: keeps firing while we re-post every poll, auto-resolves once we stop
    ends = (datetime.now(timezone.utc) + timedelta(seconds=ttl)).isoformat()
    return {"labels": {"alertname": name, "severity": severity, "namespace": NAMESPACE, **(extra_labels or {})},
            "annotations": {"summary": summary, "description": description}, "endsAt": ends}


def build_alerts(store, items, ttl=120):
    return [alert("iPhoneInStock", "critical", summary, f"Price: EGP {price:,.0f}\n{url}",
                  {"store": store, "variant": variant}, ttl)
            for variant, summary, price, url in items]


def post(alerts):
    req = urllib.request.Request(f"{ALERTMANAGER}/api/v2/alerts", data=json.dumps(alerts).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def main():
    dry = "--dry-run" in sys.argv
    srcs = sources()
    while True:
        alerts, now = [], time.monotonic()
        for s in srcs:
            if dry or now >= s.due:
                err = None
                try:
                    items = s.fetch()
                    print(f"{datetime.now():%H:%M:%S} {s.store} available={[i[0] for i in items]}", flush=True)
                    alerts += build_alerts(s.store, items, max(s.interval * 4, 120))
                except Exception as e:  # never die on a bad poll; the API or network will hiccup
                    err = e
                    print(f"{datetime.now():%H:%M:%S} {s.store} poll failed: {e!r}", flush=True)
                s.done(now, err)
            if s.stale(now):
                alerts.append(alert("iPhoneTrackerFailing", "warning", f"iPhone stock tracker cannot read {s.store}",
                                    f"No successful read for {(now - s.last_ok) / 60:.0f} min (see pod logs)\n{s.url}",
                                    {"store": s.store}))
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

    urls = ["https://tradelinestores.com/products/x", "https://tradelinestores.com/products/y"]
    assert storefront_query(["x", "y"]).count("product(handle:") == 2
    r = {"data": {"p0": {"title": "iPhone 18 Pro Max 256GB Black", "variants": {"nodes": [
        {"title": "Default Title", "availableForSale": True, "price": {"amount": "111799.0"}}]}},
        "p1": {"title": "Silver", "variants": {"nodes": [
            {"title": "1TB", "availableForSale": False, "price": {"amount": "1.0"}}]}}}}
    a = build_alerts("tradelinestores.com", shopify_items(r, urls))
    assert [x["labels"]["variant"] for x in a] == ["iPhone 18 Pro Max 256GB Black"], a
    assert "111,799" in a[0]["annotations"]["description"] and a[0]["labels"]["store"] == "tradelinestores.com"
    r["data"]["p0"]["variants"]["nodes"][0]["availableForSale"] = False
    assert shopify_items(r, urls) == []
    r["data"]["p1"] = None
    try:
        shopify_items(r, urls)
        raise AssertionError("missing product must raise")
    except LookupError:
        pass

    s = Source("t", "u", None, 60)
    e429 = urllib.error.HTTPError("u", 429, "", {"Retry-After": "60"}, None)
    s.done(1000, e429)
    s.done(1000, e429)
    s.done(1000, e429)
    assert (s.backoff, s.due) == (240, 1240), (s.backoff, s.due)
    s.done(2000)
    assert (s.backoff, s.due, s.last_ok) == (0, 2060, 2000)
    assert not s.stale(2000 + 60 * STALE_POLLS) and s.stale(2001 + 60 * STALE_POLLS)
    print("ok")


if __name__ == "__main__":
    _test() if "--test" in sys.argv else main()
