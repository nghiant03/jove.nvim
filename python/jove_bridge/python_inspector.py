import json


def _jove_vars(namespace):
    def safe_repr(value):
        try:
            return repr(value)[:120]
        except Exception:
            return "<repr failed>"

    def safe_size(value):
        try:
            return len(value)
        except Exception:
            return None

    return json.dumps(
        [
            {
                "name": name,
                "type": type(value).__name__,
                "value": safe_repr(value),
                "size": safe_size(value),
            }
            for name, value in list(namespace.items())
            if not name.startswith("_") and type(value).__name__ != "module"
        ]
    )
