"""Polls Orange EG eShop stock and fires an Alertmanager alert (-> Homealert Telegram) per in-stock variant."""
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

SE_NAME = os.environ.get("SE_NAME", "iphone-18-pro-max")
API = f"https://eshop.orange.eg/api/CatalogAPI/Products/GetProductDetails?seName={SE_NAME}"
PAGE = f"https://eshop.orange.eg/ar/smart-phones/p/{SE_NAME}"
ALERTMANAGER = os.environ.get("ALERTMANAGER_URL", "http://prometheus-alertmanager.monitoring:9093")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "30"))
FAIL_ALERT_AFTER = 20  # consecutive failed polls (~10 min at 30s) before alerting that the tracker is blind
NAMESPACE = os.environ.get("POD_NAMESPACE", "iphone-tracker")


def fetch():
    req = urllib.request.Request(API, headers={"Accept-Language": "en-US", "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["Data"]


def available_variants(d):
    names = {v["Id"]: v["Name"].strip() for a in d["Attributes"] for v in a["Values"]}
    out = [(" / ".join(names.get(a["AttributeValueId"], "?") for a in c["AttributeValues"]), c["Price"]["Amount"])
           for c in d["Combinations"] if c.get("IsAvailable")]
    # Product-level flags can flip without a per-variant one (e.g. pre-order opening)
    if not out and (d.get("InStock") or d.get("AvailableForPreOrder") or d.get("IsAvailableForPreorderWithPayment")):
        out = [("pre-order" if not d.get("InStock") else "any", d["Price"]["Amount"])]
    return out


def alert(name, severity, summary, description, extra_labels=None):
    # endsAt in the near future: keeps firing while we re-post every poll, auto-resolves once we stop
    ends = (datetime.now(timezone.utc) + timedelta(seconds=max(INTERVAL * 4, 120))).isoformat()
    return {"labels": {"alertname": name, "severity": severity, "namespace": NAMESPACE, **(extra_labels or {})},
            "annotations": {"summary": summary, "description": description}, "endsAt": ends}


def build_alerts(d):
    return [alert("iPhoneInStock", "critical", f"{d['Name']} {v} is available on Orange eShop",
                  f"Price: EGP {price:,.0f}\n{PAGE}", {"variant": v})
            for v, price in available_variants(d)]


def post(alerts):
    req = urllib.request.Request(f"{ALERTMANAGER}/api/v2/alerts", data=json.dumps(alerts).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=10).close()


def main():
    dry = "--dry-run" in sys.argv
    fails = 0
    while True:
        try:
            d = fetch()
            fails = 0
            alerts = build_alerts(d)
            print(f"{datetime.now():%H:%M:%S} in_stock={d.get('InStock')} available={[a['labels']['variant'] for a in alerts]}", flush=True)
            if alerts:
                print(json.dumps(alerts, ensure_ascii=False)) if dry else post(alerts)
        except Exception as e:  # never die on a bad poll; the API or network will hiccup
            fails += 1
            print(f"{datetime.now():%H:%M:%S} poll failed ({fails}): {e!r}", flush=True)
            if fails >= FAIL_ALERT_AFTER and not dry:
                try:
                    post([alert("iPhoneTrackerFailing", "warning", "iPhone stock tracker cannot read Orange eShop",
                                f"{fails} consecutive failed polls. Last error: {e!r}\n{API}")])
                except Exception as e2:
                    print(f"alertmanager post failed: {e2!r}", flush=True)
        if dry:
            return
        time.sleep(INTERVAL)


def _test():
    d = {"Name": "iPhone", "InStock": True, "Price": {"Amount": 1.0},
         "Attributes": [{"Values": [{"Id": 1, "Name": "Black"}, {"Id": 2, "Name": "256GB"}]}],
         "Combinations": [{"AttributeValues": [{"AttributeValueId": 1}, {"AttributeValueId": 2}],
                           "Price": {"Amount": 111799.0}, "IsAvailable": True},
                          {"AttributeValues": [{"AttributeValueId": 1}], "Price": {"Amount": 5.0}, "IsAvailable": False}]}
    a = build_alerts(d)
    assert [x["labels"]["variant"] for x in a] == ["Black / 256GB"], a
    assert "111,799" in a[0]["annotations"]["description"]
    for c in d["Combinations"]:
        c["IsAvailable"] = False
    assert [x["labels"]["variant"] for x in build_alerts(d)] == ["any"]
    d["InStock"] = False
    assert build_alerts(d) == []
    d["AvailableForPreOrder"] = True
    assert [x["labels"]["variant"] for x in build_alerts(d)] == ["pre-order"]
    print("ok")


if __name__ == "__main__":
    _test() if "--test" in sys.argv else main()
