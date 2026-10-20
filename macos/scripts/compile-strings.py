"""Writes <lang>.lproj/Localizable.strings for every language in a String Catalog."""

import json
import pathlib
import sys

catalog = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out = pathlib.Path(sys.argv[2])
source = catalog["sourceLanguage"]


def quoted(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


tables = {source: {key: key for key in catalog["strings"]}}
for key, entry in catalog["strings"].items():
    for language, localization in entry.get("localizations", {}).items():
        tables.setdefault(language, {})[key] = localization["stringUnit"]["value"]

for language, table in tables.items():
    directory = out / f"{language}.lproj"
    directory.mkdir(parents=True, exist_ok=True)
    lines = [f"{quoted(key)} = {quoted(value)};" for key, value in sorted(table.items())]
    (directory / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
