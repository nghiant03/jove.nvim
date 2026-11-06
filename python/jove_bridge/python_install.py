import hashlib
import sys
import types

source = globals()["source"]
revision = hashlib.sha256(source.encode()).hexdigest()[:16]
module = sys.modules.get("_jove_inspector")
if module is None or module.__dict__.get("_jove_rev") != revision:
    module = types.ModuleType("_jove_inspector")
    exec(source, module.__dict__)
    module._jove_rev = revision
    sys.modules["_jove_inspector"] = module
