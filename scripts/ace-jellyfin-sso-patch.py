#!/usr/bin/env python3
"""Remove OIDC groups scope from SSO-Auth.xml (complement action sets the claim)."""
import re
from pathlib import Path

path = Path('/jf/config/plugins/configurations/SSO-Auth.xml')
text = path.read_text()
text = re.sub(r'\s*<string>groups</string>\n', '\n', text)
path.write_text(text)
print('removed groups scope from', path)
