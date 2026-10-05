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


def _text(value) -> dict:
    return {"type": "text", "text": str(value)}


def send_otp(phone: str, code: str) -> None:
    """Authentication template: body {{1}} = code, plus the copy-code button (url button param = code)."""
    components = [
        {"type": "body", "parameters": [_text(code)]},
        {"type": "button", "sub_type": "url", "index": "0", "parameters": [_text(code)]},
    ]
    console = f"رمز التحقق الخاص بك هو {code}. لا تشارك هذا الرمز إلا مع الجابي المعتمد عند الدفع."
    _send_template(phone, settings.WA_TEMPLATE_OTP, components, console, preview="OTP (hidden)")


def send_bill_notice(phone: str, *, name: str, property_code: str, total: float, gov: float, fee: float,
                     collector_code: str) -> None:
    """Utility template jbaya_bill_notice:
    {{1}} name, {{2}} property code, {{3}} total, {{4}} consumption fee, {{5}} company fee, {{6}} collector, {{7}} hotline"""
    params = [name, property_code, fmt_iqd(total), fmt_iqd(gov), fmt_iqd(fee), collector_code, settings.HOTLINE]
    components = [{"type": "body", "parameters": [_text(p) for p in params]}]
    console = (
        f"عزيزي {name}،\n"
        f"المبلغ المستحق للعقار {property_code} هو {fmt_iqd(total)} د.ع "
        f"(رسوم الاستهلاك {fmt_iqd(gov)} + أجور الجباية {fmt_iqd(fee)}).\n"
        f"لا تدفع أكثر من هذا المبلغ. الجابي: {collector_code}. للشكاوى: {settings.HOTLINE}"
    )
    _send_template(phone, settings.WA_TEMPLATE_BILL_NOTICE, components, console, preview=json.dumps(params, ensure_ascii=False))


def send_receipt(phone: str, *, name: str, receipt_no: str, property_code: str, total: float, date_str: str) -> None:
    """Utility template jbaya_receipt:
    {{1}} name, {{2}} receipt no, {{3}} total, {{4}} property code, {{5}} date, {{6}} hotline"""
    params = [name, receipt_no, fmt_iqd(total), property_code, date_str, settings.HOTLINE]
    components = [{"type": "body", "parameters": [_text(p) for p in params]}]
    console = (
        f"عزيزي {name}، تم استلام {fmt_iqd(total)} د.ع للعقار {property_code}.\n"
        f"رقم الوصل: {receipt_no} بتاريخ {date_str}.\n"
        f"إذا دفعت مبلغاً أكبر يرجى الاتصال على {settings.HOTLINE}"
    )
    _send_template(phone, settings.WA_TEMPLATE_RECEIPT, components, console, preview=json.dumps(params, ensure_ascii=False))
