import os
import pathlib
import json

from verify_feishu_list_messages import load_enabled_app, get_tenant_token, get_message


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    base_path = pathlib.Path(os.environ.get("NIMCLAW_DIR", str(root / ".nimclaw"))) / "BASE.json"
    app_id, app_secret = load_enabled_app(base_path)
    token = get_tenant_token(app_id, app_secret)
    mid = os.environ.get("FEISHU_MESSAGE_ID", "")
    if not mid:
        raise SystemExit("set FEISHU_MESSAGE_ID")
    m = get_message(token, mid)
    print(
        json.dumps(
            {
                "message_id": mid,
                "msg_type": m.get("msg_type"),
                "sender_type": m.get("sender", {}).get("sender_type"),
                "body_prefix": (m.get("body", {}).get("content", "")[:400]),
            },
            ensure_ascii=False,
        )
    )
