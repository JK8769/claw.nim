import json
import os
import pathlib
import sys

import requests


def load_enabled_app(base_path: pathlib.Path):
    base = json.loads(base_path.read_text())
    apps = base["config"]["channels"]["feishu"]["apps"]
    for a in apps:
        if a.get("enabled", True) is False:
            continue
        app_id = a.get("app_id", "")
        app_secret = a.get("app_secret", "")
        if app_id and app_secret:
            return app_id, app_secret
    raise RuntimeError("no enabled feishu app in BASE.json")


def get_tenant_token(app_id: str, app_secret: str) -> str:
    r = requests.post(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        json={"app_id": app_id, "app_secret": app_secret},
        timeout=20,
    )
    r.raise_for_status()
    data = r.json()
    tok = data.get("tenant_access_token", "")
    if not tok:
        raise RuntimeError(f"missing tenant_access_token: {data}")
    return tok


def list_messages_page(token: str, chat_id: str, page_size: int = 50, page_token: str | None = None):
    params = {"container_id_type": "chat", "container_id": chat_id, "page_size": page_size}
    if page_token:
        params["page_token"] = page_token
    r = requests.get(
        "https://open.feishu.cn/open-apis/im/v1/messages",
        params=params,
        headers={"Authorization": f"Bearer {token}"},
        timeout=20,
    )
    r.raise_for_status()
    j = r.json()
    data = j.get("data", {})
    return data.get("items", []), data.get("has_more", False), data.get("page_token")

def get_message(token: str, message_id: str):
    r = requests.get(
        f"https://open.feishu.cn/open-apis/im/v1/messages/{message_id}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=20,
    )
    r.raise_for_status()
    return r.json().get("data", {}).get("items", [{}])[0]


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    base_path = pathlib.Path(os.environ.get("NIMCLAW_DIR", str(root / ".nimclaw"))) / "BASE.json"
    app_id, app_secret = load_enabled_app(base_path)
    chat_id = os.environ.get("FEISHU_TEST_CHAT_ID", "oc_136b46cfde0e7ddeddc43f24bd28e702")
    token = get_tenant_token(app_id, app_secret)
    all_items = []
    page_token = None
    for _ in range(12):
        items, has_more, next_token = list_messages_page(token, chat_id, page_size=50, page_token=page_token)
        all_items.extend(items)
        if not has_more or not next_token:
            break
        page_token = next_token

    print(json.dumps({"chat_id": chat_id, "count": len(all_items)}, ensure_ascii=False))
    for it in all_items[-10:]:
        sender = it.get("sender", {})
        sender_id = sender.get("id", "")
        sender_type = sender.get("sender_type", "")
        print(it.get("create_time"), it.get("msg_type"), it.get("message_id"), sender_type, sender_id)

    if all_items:
        mid = all_items[-1].get("message_id")
        m = get_message(token, mid)
        print("sample_content_prefix", (m.get("body", {}).get("content", "")[:200]))
