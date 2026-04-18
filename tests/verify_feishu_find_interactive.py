import os
import pathlib
import json

from verify_feishu_list_messages import load_enabled_app, get_tenant_token, list_messages_page, get_message


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    base_path = pathlib.Path(os.environ.get("NIMCLAW_DIR", str(root / ".nimclaw"))) / "BASE.json"
    app_id, app_secret = load_enabled_app(base_path)
    chat_id = os.environ.get("FEISHU_TEST_CHAT_ID", "oc_136b46cfde0e7ddeddc43f24bd28e702")
    token = get_tenant_token(app_id, app_secret)

    all_items = []
    page_token = None
    for _ in range(20):
        items, has_more, next_token = list_messages_page(token, chat_id, page_size=50, page_token=page_token)
        all_items.extend(items)
        if not has_more or not next_token:
            break
        page_token = next_token

    inter = [it for it in all_items if it.get("msg_type") == "interactive"]
    posts = [it for it in all_items if it.get("msg_type") == "post"]
    last_app = next((it for it in reversed(all_items) if it.get("sender", {}).get("sender_type") == "app"), None)
    detail = {}
    if last_app:
        mid = last_app.get("message_id")
        m = get_message(token, mid)
        detail = {
            "sample_app_message_id": mid,
            "sample_app_msg_type": m.get("msg_type"),
            "sample_app_body_prefix": (m.get("body", {}).get("content", "")[:200]),
        }
    print(
        json.dumps(
            {
                "chat_id": chat_id,
                "total": len(all_items),
                "interactive": len(inter),
                "post": len(posts),
                "last10_types": [it.get("msg_type") for it in all_items[-10:]],
                **detail,
            },
            ensure_ascii=False,
        )
    )
