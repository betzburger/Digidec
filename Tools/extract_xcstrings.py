import xml.etree.ElementTree as ET
import json
import os

xliff_path = 'de.xcloc/Localized Contents/de.xliff'
tree = ET.parse(xliff_path)
root = tree.getroot()

ns = {'xliff': 'urn:oasis:names:tc:xliff:document:1.2'}

strings_dict = {}

for trans_unit in root.findall('.//xliff:trans-unit', ns):
    source_elem = trans_unit.find('xliff:source', ns)
    if source_elem is not None and source_elem.text is not None:
        text = source_elem.text
        # Skip strings that have no letters (like "%@", " ", "-")
        if any(c.isalpha() for c in text):
            strings_dict[text] = {
                "extractionState": "manual",
                "localizations": {
                    "en": {
                        "stringUnit": {
                            "state": "needs_review",
                            "value": ""
                        }
                    }
                }
            }

xcstrings = {
    "sourceLanguage": "de",
    "strings": strings_dict,
    "version": "1.0"
}

os.makedirs('Sources/Resources', exist_ok=True)
with open('Sources/Resources/Localizable.xcstrings', 'w', encoding='utf-8') as f:
    json.dump(xcstrings, f, indent=2, ensure_ascii=False)

print(f"Created Localizable.xcstrings with {len(strings_dict)} strings to translate.")
