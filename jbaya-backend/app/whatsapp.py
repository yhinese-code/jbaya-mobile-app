"""WhatsApp Business (Meta Cloud API) gateway.

Meta rules that shape this module:
- Messages started by the business (not a reply within 24h) MUST use pre-approved templates.
- One-time codes MUST use an "Authentication" template; amounts/receipts use "Utility" templates.
  So the payment step sends TWO messages: the bill notice (amount + "do not pay more") and the code.

WHATSAPP_MODE=console prints messages in the server terminal instead of sending (development).
The plain OTP is never written to the database or returned to the collector's app.
"""
import json

import requests
from fastapi import HTTPException

from .config import settings
from .db import get_conn
from .utils import fmt_iqd


def _log(phone: str, template: str, preview: str, status: str, provider_id: str | None = None, error: str | None = None):
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO whatsapp_messages (phone, template, preview, status, provider_id, error) VALUES (%s,%s,%s,%s,%s,%s)",
                (phone, template, preview, status, provider_id, error),
            )
    except Exception as e:  # logging must never break the main flow
        print(f"[whatsapp] could not log message: {e}")


def _send_template(phone: str, template: str, components: list, console_text: str, preview: str) -> None:
    if settings.WHATSAPP_MODE != "live":
        print(f"\n[WHATSAPP console -> +{phone} | template={template}]\n{console_text}\n")
        _log(phone, template, preview, "console")
        return

    if not settings.WHATSAPP_TOKEN or not settings.WHATSAPP_PHONE_NUMBER_ID:
        raise HTTPException(500, "إعدادات واتساب غير مكتملة على الخادم")

    url = f"https://graph.facebook.com/{settings.WHATSAPP_API_VERSION}/{settings.WHATSAPP_PHONE_NUMBER_ID}/messages"
    body = {
        "messaging_product": "whatsapp",
        "to": phone,
        "type": "template",
        "template": {"name": template, "language": {"code": settings.WHATSAPP_LANG}, "components": components},
    }
    try:
        r = requests.post(url, headers={"Authorization": f"Bearer {settings.WHATSAPP_TOKEN}"}, json=body, timeout=15)
    except requests.RequestException as e:
        _log(phone, template, preview, "failed", error=str(e))
        raise HTTPException(502, "تعذر الاتصال بخدمة واتساب، حاول مجدداً")
    if r.status_code >= 300:
        _log(phone, template, preview, "failed", error=r.text[:1000])
        raise HTTPException(502, "فشل إرسال رسالة واتساب للمواطن، تأكد من الرقم وحاول مجدداً")
    msg_id = None
    try:
        msg_id = r.json()["messages"][0]["id"]
    except (ValueError, KeyError, IndexError):
        pass
    _log(phone, template, preview, "sent", provider_id=msg_id)


# The text each Meta template must be approved with (the tech panel shows it; Meta keeps the real copy).
TEMPLATE_TEXT = {
    # Meta writes the body of Authentication templates itself (only the code + an optional security line), so the
    # instruction to read the code to the employee goes in the bill notice that arrives just before it.
    "otp": "{{1}} هو رمز التحقق الخاص بك. لأمانك، لا تشارك هذا الرمز. (نص ثابت من ميتا لقوالب المصادقة)",
    "bill_notice": "عزيزي {{1}}، المبلغ المستحق للعقار {{2}} هو {{3}} د.ع (رسوم الاستهلاك {{4}} + أجور الجباية {{5}}).\n"
                   "سيصلك الآن رمز تحقق: اقرأه لموظف الجباية الذي أمامك فقط.\n"
                   "لا تدفع أكثر من هذا المبلغ. الموظف: {{6}}. للشكاوى: {{7}}",
    "receipt": "عزيزي {{1}}، تم استلام {{3}} د.ع للعقار {{4}}. رقم الوصل {{2}} بتاريخ {{5}}.\n"
               "لا تدفع أكثر من المبلغ المذكور في هذا الوصل. إذا طُلب منك مبلغ أكبر اتصل على {{6}}",
}
TEMPLATE_KIND = {"otp": "authentication", "bill_notice": "utility", "receipt": "utility"}


def window_open(phone: str, cur=None) -> bool:
    """True when the citizen messaged us within the last 24 hours (minus a safety margin): inside this window Meta
    lets us send normal text messages for free."""
    sql = """SELECT 1 FROM whatsapp_inbound WHERE phone = %s
             AND COALESCE(sent_at, received_at) > NOW() - INTERVAL '24 hours' + (%s || ' minutes')::interval LIMIT 1"""
    args = (phone, settings.WINDOW_SAFETY_MINUTES)
    try:
        if cur is not None:
            cur.execute(sql, args)
            return cur.fetchone() is not None
        with get_conn() as conn, conn.cursor() as c:
            c.execute(sql, args)
            return c.fetchone() is not None
    except Exception as e:  # never block a payment on this check
        print(f"[whatsapp] window check failed: {e}")
        return False


def send_text(phone: str, body: str, kind: str) -> None:
    """A normal text message inside the citizen's 24-hour window (free). Logged as status 'free'.
    The preview never contains a code: kind 'otp' is logged without its text."""
    preview = "OTP (hidden)" if kind == "otp" else body[:300]
    if settings.WHATSAPP_MODE != "live":
        print(f"\n[WHATSAPP console -> +{phone} | free text:{kind}]\n{body}\n")
        _log(phone, f"text:{kind}", preview, "console")
        return
    if not settings.WHATSAPP_TOKEN or not settings.WHATSAPP_PHONE_NUMBER_ID:
        raise HTTPException(500, "إعدادات واتساب غير مكتملة على الخادم")
    url = f"https://graph.facebook.com/{settings.WHATSAPP_API_VERSION}/{settings.WHATSAPP_PHONE_NUMBER_ID}/messages"
    payload = {"messaging_product": "whatsapp", "to": phone, "type": "text", "text": {"body": body}}
    try:
        r = requests.post(url, headers={"Authorization": f"Bearer {settings.WHATSAPP_TOKEN}"}, json=payload, timeout=15)
    except requests.RequestException as e:
        _log(phone, f"text:{kind}", preview, "failed", error=str(e))
        raise HTTPException(502, "تعذر الاتصال بخدمة واتساب، حاول مجدداً")
    if r.status_code >= 300:
        _log(phone, f"text:{kind}", preview, "failed", error=r.text[:1000])
        raise HTTPException(502, "فشل إرسال رسالة واتساب للمواطن")
    msg_id = None
    try:
        msg_id = r.json()["messages"][0]["id"]
    except (ValueError, KeyError, IndexError):
        pass
    _log(phone, f"text:{kind}", preview, "free", provider_id=msg_id)


def fill(template_key: str, params: list) -> str:
    text = TEMPLATE_TEXT[template_key]
    for i, p in enumerate(params, 1):
        text = text.replace("{{%d}}" % i, str(p))
    return text


def code_text(code: str) -> str:
    return (f"رمز التحقق: {code}\n"
            "اقرأ هذا الرمز لموظف الجباية الذي أمامك فقط. لا ترسله لأي شخص عبر الهاتف أو الرسائل.")


def _text(value) -> dict:
    return {"type": "text", "text": str(value)}


def send_otp(phone: str, code: str) -> None:
    """Authentication template: body {{1}} = code, plus the copy-code button (url button param = code)."""
    components = [
        {"type": "body", "parameters": [_text(code)]},
        {"type": "button", "sub_type": "url", "index": "0", "parameters": [_text(code)]},
    ]
    console = f"{code} هو رمز التحقق الخاص بك. اقرأه لموظف الجباية الذي أمامك فقط."
    _send_template(phone, settings.WA_TEMPLATE_OTP, components, console, preview="OTP (hidden)")


def send_bill_notice(phone: str, *, name: str, property_code: str, total: float, gov: float, fee: float,
                     collector_code: str) -> None:
    """Utility template jbaya_bill_notice:
    {{1}} name, {{2}} property code, {{3}} total, {{4}} consumption fee, {{5}} company fee, {{6}} collector, {{7}} hotline"""
    params = [name, property_code, fmt_iqd(total), fmt_iqd(gov), fmt_iqd(fee), collector_code, settings.HOTLINE]
    if settings.CITIZEN_FIRST_MESSAGE and window_open(phone):
        send_text(phone, fill("bill_notice", params), "bill_notice")
        return
    components = [{"type": "body", "parameters": [_text(p) for p in params]}]
    console = TEMPLATE_TEXT["bill_notice"]
    for i, p in enumerate(params, 1):
        console = console.replace("{{%d}}" % i, str(p))
    _send_template(phone, settings.WA_TEMPLATE_BILL_NOTICE, components, console, preview=json.dumps(params, ensure_ascii=False))


def send_receipt(phone: str, *, name: str, receipt_no: str, property_code: str, total: float, date_str: str) -> None:
    """Utility template jbaya_receipt:
    {{1}} name, {{2}} receipt no, {{3}} total, {{4}} property code, {{5}} date, {{6}} hotline"""
    params = [name, receipt_no, fmt_iqd(total), property_code, date_str, settings.HOTLINE]
    if settings.CITIZEN_FIRST_MESSAGE and window_open(phone):
        send_text(phone, fill("receipt", params), "receipt")       # free inside the citizen's window
        return
    components = [{"type": "body", "parameters": [_text(p) for p in params]}]
    console = TEMPLATE_TEXT["receipt"]
    for i, p in enumerate(params, 1):
        console = console.replace("{{%d}}" % i, str(p))
    _send_template(phone, settings.WA_TEMPLATE_RECEIPT, components, console, preview=json.dumps(params, ensure_ascii=False))
