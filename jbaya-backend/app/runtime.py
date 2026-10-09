"""Runtime settings, switches and permissions (Phase 5, the tech panel's "god mode").

Every value in REGISTRY starts from config.py / .env and can be overridden from the tech panel.
Overrides live in the `system_settings` table and are applied onto the shared `settings` object, so all
existing code keeps reading `settings.X` and sees the new value within a few seconds (every worker refreshes).
Every change is written to `setting_changes` and to the audit log.
"""
import json
import time
from datetime import datetime

from fastapi import HTTPException

from . import audit
from .config import settings

# key: (type, group, Arabic label, help, owner may edit, extra)
# types: int, float, bool, str, choice, time, list_int, list_str, map_int
REGISTRY: dict[str, tuple] = {
    # ---- money
    "COMPANY_FEE_IQD": ("float", "money", "أجور الجباية على كل وصل (د.ع)", "تُضاف إلى كل فاتورة", False, {"min": 0}),
    "ROUND_TO_IQD": ("int", "money", "تقريب المبالغ إلى", "أصغر فئة نقدية عملية", False, {"min": 1}),
    "COMPANY_SHARE_PCT": ("float", "money", "نسبة ثابتة من مبلغ الماء للشركة %", "قديم: اتركه 0 إذا كانت الشركة تأخذ نسبة الزيادة فقط", False, {"min": 0, "max": 100}),
    "GAIN_SHARE_MODE": ("choice", "money", "طريقة احتساب نسبة الزيادة", "لم تُحدد = تقديرات فقط بلا قيد", False,
                        {"choices": {"not_set": "لم تُحدد بعد", "baseline_2025": "فوق إيرادات 2025 لنفس الشهر", "per_house": "زيادة كل منزل عن فاتورته السابقة"}}),
    "GAIN_SHARE_PCT": ("float", "money", "نسبة الشركة من الزيادة %", "حسب العقد (35%)", False, {"min": 0, "max": 100}),
    "PREV_BILL_OUTLIER_FACTOR": ("float", "money", "الفاتورة السابقة الشاذة (أضعاف معدل الفئة)", "", False, {"min": 1}),
    # ---- cash
    "CASH_IN_HAND_CAP_IQD": ("float", "cash", "الحد الأعلى للنقد بيد الجابي", "تتوقف الجباية عند بلوغه", True, {"min": 0}),
    "RECON_TOLERANCE_IQD": ("float", "cash", "فرق مقبول عند تسليم الجابي", "", False, {"min": 0}),
    "HANDOVER_TOLERANCE_IQD": ("float", "cash", "فرق مقبول عند تسليم المشرف للمالية", "", False, {"min": 0}),
    "OWNER_APPROVAL_IQD": ("float", "cash", "حد موافقة المالك", "الشطب والتصحيحات فوقه تنتظر المالك", True, {"min": 0}),
    "CASH_OUTSIDE_HQ_ALERT_IQD": ("float", "cash", "تنبيه النقد خارج المقر", "", True, {"min": 0}),
    # ---- billing
    "FIRST_VISIT_PERIOD_DAYS": ("int", "billing", "مدة فاتورة الزيارة الأولى (يوم)", "", False, {"min": 1}),
    "HIGH_CONSUMPTION_FACTOR": ("float", "billing", "استهلاك مرتفع (أضعاف المعدل)", "", False, {"min": 1}),
    "OCR_MISMATCH_TOLERANCE": ("float", "billing", "فرق مسموح بين الكاميرا والقراءة (م³)", "", False, {"min": 0}),
    "ROUTE_DUE_DAYS": ("int", "billing", "العقار مستحق بعد (يوم)", "", False, {"min": 1}),
    "ROUTE_WARNING_DAYS": ("int", "billing", "العقار قيد النضوج بعد (يوم)", "", False, {"min": 1}),
    # ---- field
    "MAX_DISTANCE_FROM_PROPERTY_M": ("float", "field", "أقصى بعد عن العقار عند الجباية (م)", "", False, {"min": 5}),
    "MAX_GPS_ACCURACY_METERS": ("float", "field", "أسوأ دقة موقع مقبولة (م)", "", False, {"min": 5}),
    "DUPLICATE_RADIUS_M": ("float", "field", "مسافة الاشتباه بالتكرار (م)", "", False, {"min": 1}),
    "MAX_PLAUSIBLE_SPEED_MPS": ("float", "field", "سرعة غير منطقية (م/ث)", "", False, {"min": 1}),
    "PING_ONLINE_SECONDS": ("int", "field", "يُعد متصلاً إذا وصل موقعه خلال (ث)", "", False, {"min": 30}),
    "ENFORCE_GEOFENCE": ("bool", "field", "منع التسجيل خارج القاطع", "", False, {}),
    "REQUIRE_METER_PHOTO": ("bool", "field", "صورة العداد إلزامية", "", False, {}),
    # ---- codes
    "OTP_TTL_SECONDS": ("int", "codes", "صلاحية رمز المواطن (ث)", "", False, {"min": 60}),
    "OTP_MAX_ATTEMPTS": ("int", "codes", "محاولات رمز المواطن", "", False, {"min": 1, "max": 10}),
    "OTP_RESEND_COOLDOWN_SECONDS": ("int", "codes", "انتظار قبل إعادة الإرسال (ث)", "", False, {"min": 0}),
    "MASTER_CODE_WINDOW_SECONDS": ("int", "codes", "تغيير الرمز الرئيسي كل (ث)", "", False, {"min": 60}),
    "MASTER_CODE_DAILY_LIMIT_PER_COLLECTOR": ("int", "codes", "استخدامات الرمز الرئيسي يومياً لكل جابي", "", True, {"min": 0}),
    "MASTER_CODE_MAX_FAILED_PER_DAY": ("int", "codes", "محاولات خاطئة للرمز الرئيسي يومياً", "", False, {"min": 1}),
    # ---- fraud
    "MAX_PROPERTIES_PER_PHONE": ("int", "fraud", "رقم مواطن على أكثر من (عقار) = إشارة", "", False, {"min": 1}),
    "PHONE_HARD_LIMIT_PROPERTIES": ("int", "fraud", "رقم مواطن على أكثر من (عقار) = رفض", "", False, {"min": 1}),
    "FAST_OTP_SECONDS": ("int", "fraud", "رمز أُدخل أسرع من (ث) = إشارة", "المواطن يحتاج وقتاً ليقرأ الرمز", False, {"min": 0}),
    "PHONE_SPREAD_KM": ("float", "fraud", "رقم واحد على منازل متباعدة أكثر من (كم)", "", False, {"min": 0.1}),
    "CALLBACK_DAILY_SAMPLE": ("int", "fraud", "عدد وصولات الاتصال العشوائي يومياً", "", True, {"min": 0}),
    # ---- HR
    "SHIFT_START": ("time", "hr", "بداية الدوام", "", False, {}),
    "LATE_GRACE_MINUTES": ("int", "hr", "سماح التأخير (دقيقة)", "", False, {"min": 0}),
    "WEEKEND_DAYS": ("list_int", "hr", "أيام العطلة (0=الاثنين ... 4=الجمعة)", "", False, {}),
    "REQUIRE_SELFIE": ("bool", "hr", "صورة شخصية عند الحضور", "", False, {}),
    "LEAVE_ANNUAL_DAYS": ("int", "hr", "إجازة سنوية (يوم)", "", False, {"min": 0}),
    "LEAVE_SICK_DAYS": ("int", "hr", "إجازة مرضية (يوم)", "", False, {"min": 0}),
    "LEAVE_EMERGENCY_DAYS": ("int", "hr", "إجازة طارئة (يوم)", "", False, {"min": 0}),
    "COMMISSION_PER_RECEIPT_IQD": ("float", "hr", "عمولة الوصل المؤكد برمز المواطن", "", False, {"min": 0}),
    "INCOME_TAX_PCT": ("float", "hr", "ضريبة الدخل %", "", False, {"min": 0, "max": 100}),
    "SOCIAL_SECURITY_PCT": ("float", "hr", "الضمان الاجتماعي (حصة الموظف) %", "", False, {"min": 0, "max": 100}),
    "WARNINGS_BEFORE_SUSPENSION": ("int", "hr", "إنذارات قبل الإيقاف", "", False, {"min": 1}),
    # ---- performance
    "COLLECTOR_DAILY_TARGET_IQD": ("float", "performance", "الهدف اليومي الافتراضي (د.ع)", "", True, {"min": 0}),
    "LOSING_STREAK_ALERT_DAYS": ("int", "performance", "أيام متتالية دون الكلفة قبل التنبيه", "", True, {"min": 1}),
    # ---- security
    "DEVICE_APPROVAL_REQUIRED": ("bool", "security", "الجهاز الجديد يحتاج موافقة التقنية", "", False, {}),
    "DEVICE_LIMITS": ("map_int", "security", "عدد الأجهزة المسموح لكل دور", "", False, {}),
    "IP_RESTRICTED_ROLES": ("list_str", "security", "أدوار تدخل من عناوين محددة فقط", "", False, {}),
    "COMMAND_IP_ALLOWLIST": ("list_str", "security", "العناوين المسموحة (IP أو شبكة)", "فارغ = أي عنوان", False, {}),
    "DAILY_LOGOUT_AT": ("time", "security", "خروج الجميع يومياً عند", "", False, {}),
    # ---- switches
    "COLLECTION_ENABLED": ("bool", "switches", "الجباية مفعلة", "إيقاف عام لكل القواطع", False, {}),
    "REGISTRATION_ENABLED": ("bool", "switches", "تسجيل العقارات مفعل", "", False, {}),
    "MASTER_CODE_ENABLED": ("bool", "switches", "الرمز الرئيسي مفعل", "", False, {}),
    "ESTIMATES_ENABLED": ("bool", "switches", "الفواتير التقديرية مسموحة", "", False, {}),
    "MAINTENANCE_MODE": ("bool", "switches", "وضع الصيانة (قراءة فقط)", "لا يُحفظ أي تغيير إلا من التقنية", False, {}),
    # ---- WhatsApp
    "WHATSAPP_MODE": ("choice", "whatsapp", "وضع واتساب", "", False, {"choices": {"console": "تجريبي (لا يُرسل)", "live": "إرسال فعلي"}}),
    "WA_TEMPLATE_OTP": ("str", "whatsapp", "قالب رمز المواطن", "يجب أن يكون معتمداً من ميتا", False, {}),
    "WA_TEMPLATE_BILL_NOTICE": ("str", "whatsapp", "قالب إشعار المبلغ", "", False, {}),
    "WA_TEMPLATE_RECEIPT": ("str", "whatsapp", "قالب الوصل", "", False, {}),
    "WHATSAPP_LANG": ("str", "whatsapp", "لغة القوالب", "", False, {}),
    "HOTLINE": ("str", "whatsapp", "رقم الشكاوى", "", False, {}),
    "WHATSAPP_COST_USD": ("float", "whatsapp", "كلفة الرسالة (دولار)", "", False, {"min": 0}),
    "CITIZEN_FIRST_MESSAGE": ("bool", "whatsapp", "المواطن يراسلنا أولاً (رسائل مجانية)",
                              "يرسل المواطن رسالة لرقم الشركة فنرسل له الرمز والوصل مجاناً داخل نافذة 24 ساعة", False, {}),
    "CITIZEN_WAIT_MINUTES": ("int", "whatsapp", "مدة انتظار رسالة المواطن (دقيقة)", "", False, {"min": 1, "max": 120}),
    "WHATSAPP_BUSINESS_NUMBER": ("str", "whatsapp", "رقم واتساب الشركة", "بصيغة 9647XXXXXXXXX", False, {}),
    "WINDOW_SAFETY_MINUTES": ("int", "whatsapp", "هامش أمان نافذة الـ24 ساعة (دقيقة)", "", False, {"min": 0, "max": 600}),
    "OFFLINE_MAX_HOURS": ("int", "field", "العمل دون اتصال المتأخر أكثر من (ساعة) = إشارة", "", False, {"min": 1}),
    # ---- UI permissions (which role sees which tab); edited as a matrix
    "UI_PERMISSIONS": ("json", "permissions", "صلاحيات العرض", "", False, {}),
}

GROUP_LABELS = {
    "money": "المال والمعادلات", "cash": "النقد", "billing": "الفوترة", "field": "الميدان", "codes": "الرموز",
    "fraud": "مكافحة التلاعب", "hr": "الموارد البشرية والضرائب", "performance": "الأداء", "security": "الدخول والأجهزة",
    "switches": "المفاتيح", "whatsapp": "واتساب", "permissions": "الصلاحيات",
}

# Tabs each role can be allowed or denied (the tech panel edits this matrix). Everything is on by default.
FEATURES: dict[str, dict[str, str]] = {
    "collector": {"collector.register": "تسجيل المواطنين", "collector.collect": "الجباية الدورية", "collector.receipts": "وصولاتي",
                  "collector.coach": "رسالة الأداء"},
    "supervisor": {"supervisor.field": "العمل الميداني", "supervisor.team": "الفريق", "supervisor.recon": "المطابقة النقدية",
                   "supervisor.reviews": "مراجعة الفواتير", "supervisor.handover": "التسليم للمالية",
                   "supervisor.performance": "أداء الفريق", "supervisor.sos": "الاستغاثات", "supervisor.attendance": "حضور الفريق",
                   "supervisor.leave": "إجازات الفريق", "supervisor.appraisals": "تقييم الفريق",
                   "supervisor.prev_bills": "الفواتير السابقة"},
    "command": {"command.live": "العمليات الحية", "command.trail": "تتبع المسار", "command.sectors": "القواطع والأداء",
                "command.receipts": "سجل الإيصالات", "command.messages": "التوجيهات", "command.master_code": "الرمز الرئيسي",
                "command.sos": "الاستغاثات", "command.differences": "فروقات نقدية", "command.fin_risk": "المخاطر المالية",
                "command.performance": "الأداء والتعادل", "command.callbacks": "الاتصال العشوائي", "command.health": "صحة النظام"},
    "finance": {"finance.today": "اليوم", "finance.receive": "استلام النقد", "finance.box": "الصندوق والمصرف",
                "finance.trust": "أمانة دائرة الماء", "finance.book": "دفتر الحساب", "finance.differences": "الفروقات",
                "finance.performance": "الأداء والتعادل", "finance.gain_share": "صيغة الـ35%", "finance.prev_bills": "الفواتير السابقة",
                "finance.company_income": "رؤية دخل الشركة الشهري", "finance.forecast": "التنبؤ", "finance.fraud": "كشف التلاعب",
                "finance.arrears": "المتأخرات", "finance.payroll": "الرواتب", "finance.expenses": "مصاريف الموظفين"},
    "owner": {"owner.summary": "الملخص", "owner.approvals": "الموافقات", "owner.pnl": "الربح والخسارة",
              "owner.performance": "الأداء والتعادل", "owner.gain_share": "صيغة الـ35%", "owner.settings": "إعدادات المالك",
              "owner.collection": "التحصيل", "owner.accounts": "كل الحسابات", "owner.finance_log": "سجل المالية",
              "owner.fraud": "كشف التلاعب", "owner.forecast": "التنبؤ", "owner.arrears": "المتأخرات"},
    "hr": {"hr.dashboard": "لوحة القيادة", "hr.employees": "الموظفون", "hr.attendance": "الحضور", "hr.leave": "الإجازات",
           "hr.payroll": "الرواتب", "hr.expenses": "المصاريف", "hr.appraisals": "التقييم", "hr.custody": "العهد",
           "hr.recruitment": "التوظيف", "hr.training": "التدريب"},
}
# a few things are off by default
DEFAULT_OFF: set[str] = set()

_DEFAULTS: dict = {}
_APPLIED: set[str] = set()        # keys this process took from system_settings (restored when the row disappears)
_last_refresh = 0.0
REFRESH_SECONDS = 5


def _capture_defaults() -> None:
    if not _DEFAULTS:
        for k in REGISTRY:
            if k == "UI_PERMISSIONS":
                _DEFAULTS[k] = {}
            else:
                _DEFAULTS[k] = getattr(settings, k)
        settings.UI_PERMISSIONS = {}


_capture_defaults()


def default(key: str):
    return _DEFAULTS[key]


def coerce(key: str, value):
    """Validates a value from the tech panel; raises 422 with an Arabic message."""
    if key not in REGISTRY:
        raise HTTPException(404, "إعداد غير معروف")
    typ, _g, label, _h, _o, extra = REGISTRY[key]
    try:
        if typ == "int":
            v = int(value)
        elif typ == "float":
            v = float(value)
        elif typ == "bool":
            v = value if isinstance(value, bool) else str(value).lower() in ("1", "true", "yes", "on")
        elif typ == "str":
            v = str(value).strip()
            if not v:
                raise ValueError
        elif typ == "choice":
            v = str(value)
            if v not in extra["choices"]:
                raise ValueError
        elif typ == "time":
            v = str(value).strip()
            datetime.strptime(v, "%H:%M")
        elif typ == "list_int":
            items = value if isinstance(value, list) else [x for x in str(value).split(",") if x.strip()]
            v = sorted({int(x) for x in items})
            if any(x < 0 or x > 6 for x in v):
                raise ValueError
        elif typ == "list_str":
            items = value if isinstance(value, list) else str(value).split(",")
            v = [str(x).strip() for x in items if str(x).strip()]
        elif typ == "map_int":
            if not isinstance(value, dict):
                raise ValueError
            v = {str(k): int(n) for k, n in value.items()}
            if any(n < 0 for n in v.values()):
                raise ValueError
        elif typ == "json":
            if not isinstance(value, dict):
                raise ValueError
            v = value
        else:
            raise ValueError
    except (TypeError, ValueError):
        raise HTTPException(422, f"قيمة غير صالحة لـ «{label}»")
    if typ in ("int", "float"):
        if "min" in extra and v < extra["min"]:
            raise HTTPException(422, f"«{label}» يجب ألا يقل عن {extra['min']}")
        if "max" in extra and v > extra["max"]:
            raise HTTPException(422, f"«{label}» يجب ألا يزيد عن {extra['max']}")
    return v


def refresh(cur, force: bool = False) -> None:
    """Applies the stored overrides onto `settings`. Keys without an override keep whatever they have."""
    global _last_refresh
    now = time.monotonic()
    if not force and now - _last_refresh < REFRESH_SECONDS:
        return
    _last_refresh = now
    try:
        cur.execute("SELECT key, value FROM system_settings")
    except Exception:
        return
    present = set()
    for r in cur.fetchall():
        k, v = r["key"], r["value"]
        if k in REGISTRY:
            try:
                setattr(settings, k, coerce(k, v))
                present.add(k)
            except HTTPException:
                pass
    for k in _APPLIED - present:       # reset from the tech panel (possibly in another worker)
        setattr(settings, k, _DEFAULTS[k])
    _APPLIED.clear()
    _APPLIED.update(present)


def mark_stale() -> None:
    global _last_refresh
    _last_refresh = 0.0


def set_value(cur, key: str, value, actor: dict, note: str | None = None) -> dict:
    v = coerce(key, value)
    old = getattr(settings, key)
    cur.execute(
        """INSERT INTO system_settings (key, value, updated_by, updated_at) VALUES (%s, %s, %s, NOW())
           ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = NOW()""",
        (key, json.dumps(v, ensure_ascii=False), actor["id"]),
    )
    cur.execute("INSERT INTO setting_changes (key, old_value, new_value, changed_by, note) VALUES (%s,%s,%s,%s,%s)",
                (key, json.dumps(old, ensure_ascii=False, default=str), json.dumps(v, ensure_ascii=False), actor["id"], note))
    audit.log(cur, actor["id"], "setting_changed", "setting", key, {"old": old, "new": v, "note": note})
    setattr(settings, key, v)
    _APPLIED.add(key)
    mark_stale()
    return {"key": key, "value": v, "old": old}


def reset_value(cur, key: str, actor: dict) -> dict:
    if key not in REGISTRY:
        raise HTTPException(404, "إعداد غير معروف")
    old = getattr(settings, key)
    cur.execute("DELETE FROM system_settings WHERE key = %s", (key,))
    cur.execute("INSERT INTO setting_changes (key, old_value, new_value, changed_by, note) VALUES (%s,%s,NULL,%s,'reset')",
                (key, json.dumps(old, ensure_ascii=False, default=str), actor["id"]))
    audit.log(cur, actor["id"], "setting_reset", "setting", key, {"old": old})
    setattr(settings, key, _DEFAULTS[key])
    _APPLIED.discard(key)
    return {"key": key, "value": _DEFAULTS[key], "old": old}


def describe(cur, only_owner: bool = False) -> list[dict]:
    cur.execute("SELECT key, updated_at, updated_by FROM system_settings")
    over = {r["key"]: r for r in cur.fetchall()}
    cur.execute("SELECT key FROM owner_editable_settings")
    owner_keys = {r["key"] for r in cur.fetchall()}
    out = []
    for k, (typ, group, label, help_, owner_default, extra) in REGISTRY.items():
        if typ == "json":
            continue
        owner_ok = k in owner_keys if owner_keys else owner_default
        if only_owner and not owner_ok:
            continue
        out.append({
            "key": k, "type": typ, "group": group, "group_label": GROUP_LABELS[group], "label": label, "help": help_,
            "value": getattr(settings, k), "default": _DEFAULTS[k], "overridden": k in over,
            "updated_at": over[k]["updated_at"].isoformat() if k in over else None,
            "owner_editable": owner_ok, "choices": extra.get("choices"), "min": extra.get("min"), "max": extra.get("max"),
        })
    return out


def owner_may_edit(cur, key: str) -> bool:
    cur.execute("SELECT key FROM owner_editable_settings")
    keys = {r["key"] for r in cur.fetchall()}
    if keys:
        return key in keys
    return bool(REGISTRY.get(key, (None,) * 5)[4])


# ---------------------------------------------------------------- permissions

def permissions_for(role: str) -> dict[str, bool]:
    feats = FEATURES.get(role, {})
    stored = (settings.UI_PERMISSIONS or {}).get(role, {})
    return {f: bool(stored.get(f, f not in DEFAULT_OFF)) for f in feats}


def allowed(role: str, feature: str) -> bool:
    if role in ("tech", "admin"):
        return True
    role_of_feature = feature.split(".", 1)[0]
    if role_of_feature != role:
        return True          # features belong to one portal; other roles are not limited by it
    return permissions_for(role).get(feature, True)


# The matrix is enforced on the server too: (role, path prefix, feature). The first matching prefix wins.
# Paths not listed here are not limited by the matrix (they are still limited by role).
PATH_FEATURES: list[tuple[str, str, str]] = [
    ("collector", "/registrations", "collector.register"),
    ("collector", "/collector/properties", "collector.collect"),
    ("collector", "/collector/route", "collector.collect"),
    ("collector", "/bills", "collector.collect"),
    ("collector", "/collector/receipts", "collector.receipts"),
    ("collector", "/collector/coach", "collector.coach"),
    ("supervisor", "/registrations", "supervisor.field"),
    ("supervisor", "/bills", "supervisor.field"),
    ("supervisor", "/collector/", "supervisor.field"),
    ("supervisor", "/supervisor/reconciliations", "supervisor.recon"),
    ("supervisor", "/supervisor/reviews", "supervisor.reviews"),
    ("supervisor", "/supervisor/bills", "supervisor.reviews"),
    ("supervisor", "/supervisor/prev-bills", "supervisor.prev_bills"),
    ("supervisor", "/prev-bills", "supervisor.prev_bills"),
    ("supervisor", "/supervisor/cash", "supervisor.handover"),
    ("supervisor", "/supervisor/handovers", "supervisor.handover"),
    ("supervisor", "/supervisor/performance", "supervisor.performance"),
    ("supervisor", "/supervisor/team", "supervisor.team"),
    ("supervisor", "/hr/attendance", "supervisor.attendance"),
    ("supervisor", "/hr/leave", "supervisor.leave"),
    ("supervisor", "/hr/appraisals", "supervisor.appraisals"),
    ("command", "/command/trail", "command.trail"),
    ("command", "/command/leaderboard", "command.sectors"),
    ("command", "/command/receipts", "command.receipts"),
    ("command", "/command/messages", "command.messages"),
    ("command", "/command/master-code", "command.master_code"),
    ("command", "/command/escalations", "command.differences"),
    ("command", "/command/callbacks", "command.callbacks"),
    ("command", "/command/health", "command.health"),
    ("command", "/performance/collectors", "command.performance"),
    ("command", "/finance/risk", "command.fin_risk"),
    ("command", "/finance/anomalies", "command.fin_risk"),
    ("command", "/finance/benford", "command.fin_risk"),
    ("finance", "/finance/handovers", "finance.receive"),
    ("finance", "/finance/transfers", "finance.box"),
    ("finance", "/finance/trust", "finance.trust"),
    ("finance", "/finance/remittances", "finance.trust"),
    ("finance", "/finance/book", "finance.book"),
    ("finance", "/finance/journal", "finance.book"),
    ("finance", "/finance/accounts", "finance.book"),
    ("finance", "/finance/differences", "finance.differences"),
    ("finance", "/finance/escalations", "finance.differences"),
    ("finance", "/finance/reconciliations", "finance.differences"),
    ("finance", "/performance/collectors", "finance.performance"),
    ("finance", "/finance/gain-share", "finance.gain_share"),
    ("finance", "/prev-bills", "finance.prev_bills"),
    ("finance", "/supervisor/prev-bills", "finance.prev_bills"),
    ("finance", "/finance/forecast", "finance.forecast"),
    ("finance", "/finance/risk", "finance.fraud"),
    ("finance", "/finance/anomalies", "finance.fraud"),
    ("finance", "/finance/benford", "finance.fraud"),
    ("finance", "/finance/aging", "finance.arrears"),
    ("finance", "/hr/payroll", "finance.payroll"),
    ("finance", "/hr/expenses", "finance.expenses"),
    ("owner", "/owner/approvals", "owner.approvals"),
    ("owner", "/owner/finance-log", "owner.finance_log"),
    ("owner", "/owner/settings", "owner.settings"),
    ("owner", "/owner/performance", "owner.performance"),
    ("owner", "/finance/income-statement", "owner.pnl"),
    ("owner", "/finance/trial-balance", "owner.accounts"),
    ("owner", "/finance/book", "owner.accounts"),
    ("owner", "/finance/gain-share", "owner.gain_share"),
    ("owner", "/finance/forecast", "owner.forecast"),
    ("owner", "/finance/risk", "owner.fraud"),
    ("owner", "/finance/anomalies", "owner.fraud"),
    ("owner", "/finance/benford", "owner.fraud"),
    ("owner", "/finance/aging", "owner.arrears"),
    ("hr", "/hr/employees", "hr.employees"),
    ("hr", "/hr/documents", "hr.employees"),
    ("hr", "/hr/discipline", "hr.employees"),
    ("hr", "/hr/attendance", "hr.attendance"),
    ("hr", "/hr/leave", "hr.leave"),
    ("hr", "/hr/payroll", "hr.payroll"),
    ("hr", "/hr/expenses", "hr.expenses"),
    ("hr", "/hr/appraisals", "hr.appraisals"),
    ("hr", "/hr/custody", "hr.custody"),
    ("hr", "/hr/openings", "hr.recruitment"),
    ("hr", "/hr/applicants", "hr.recruitment"),
    ("hr", "/hr/training", "hr.training"),
]


def feature_for_path(role: str, path: str) -> str | None:
    for r, prefix, feature in PATH_FEATURES:
        if r == role and path.startswith(prefix):
            return feature
    return None


def require_feature(user: dict, feature: str) -> None:
    if not allowed(user["role"], feature):
        raise HTTPException(403, "هذا القسم غير مفعل لحسابك")


# ---------------------------------------------------------------- effective switches (global AND sector AND person)

SWITCHES = {"collection": "COLLECTION_ENABLED", "registration": "REGISTRATION_ENABLED",
            "master_code": "MASTER_CODE_ENABLED", "estimates": "ESTIMATES_ENABLED"}
SWITCH_LABELS = {"collection": "الجباية", "registration": "تسجيل العقارات", "master_code": "الرمز الرئيسي", "estimates": "الفواتير التقديرية"}


def check_switch(cur, name: str, user: dict, sector_id: int | None = None) -> None:
    label = SWITCH_LABELS[name]
    if not getattr(settings, SWITCHES[name]):
        raise HTTPException(423, f"{label} متوقفة حالياً من الإدارة التقنية")
    sid = sector_id if sector_id is not None else user.get("sector_id")
    if sid:
        cur.execute("SELECT switches, name FROM sectors WHERE id = %s", (sid,))
        s = cur.fetchone()
        if s and (s["switches"] or {}).get(name) is False:
            raise HTTPException(423, f"{label} متوقفة في {s['name']}")
    cur.execute("SELECT permissions FROM employees WHERE id = %s", (user["id"],))
    e = cur.fetchone()
    if e and (e["permissions"] or {}).get(name) is False:
        raise HTTPException(423, f"{label} غير مسموحة لحسابك، راجع الإدارة")
