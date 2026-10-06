"""The demo history must keep the books balanced and the detectors must single out the dishonest demo collector."""
import sys

from test_flows import client, login  # noqa: F401  (must come first: it points the app at the test database)

from app import demo_finance  # noqa: E402


def test_demo_history_and_detectors(client, monkeypatch):
    monkeypatch.setattr(sys, "argv", ["demo_finance", "--yes"])
    demo_finance.main()
    demo_finance.main()                     # second run is a no-op
    fn = login(client, "FN-01")
    tb = client.get("/finance/trial-balance", headers=fn).json()
    assert tb["balanced"] and tb["cash"]["bank"] > 0 and tb["cash"]["employee_receivables"] > 0

    risk = {c["employee_code"]: c for c in client.get("/finance/risk?days=90", headers=fn).json()["collectors"]}
    honest, shady = risk["JB-0492"], risk["JB-0493"]
    assert honest["level"] == "low" and shady["score"] >= honest["score"] + 30
    pts = {f["key"]: f["points"] for f in shady["factors"]}
    assert pts["digits"] == 10 and pts["shortage"] > 10 and pts["master"] > 5

    an = client.get("/finance/anomalies?days=90", headers=fn).json()["items"]
    assert any(a["type"] == "digit_preference" and a["collector"] == "JB-0493" for a in an)
    assert not any(a["type"] in ("digit_preference", "master_share", "shortage") and a["collector"] == "JB-0492" for a in an)

    fc = client.get("/finance/forecast", headers=fn).json()
    assert fc["available"] and fc["method"] == "holt_winters" and fc["history_days"] >= 80
    friday = next(w for w in fc["weekday_profile"] if w["weekday"] == 4)
    assert friday["avg"] == 0

    bf = client.get("/finance/benford?collector=JB-0493", headers=fn).json()
    assert bf["last_digit"]["suspicious"] is True
