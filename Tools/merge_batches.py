import json
import os

merged_dict = {}

for i in range(4):
    filepath = f'Tools/batch_{i}_translated.json'
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
            merged_dict.update(data)
    else:
        print(f"Error: {filepath} not found!")

# Now structure it back to xcstrings format
xcstrings = {
    "sourceLanguage": "de",
    "strings": {},
    "version": "1.0"
}

for key, val in merged_dict.items():
    xcstrings["strings"][key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": val
                }
            }
        }
    }

# Read original to check total keys
with open('Sources/Resources/Localizable.xcstrings', 'r', encoding='utf-8') as f:
    orig = json.load(f)
    print(f"Original keys: {len(orig['strings'])}")

with open('Sources/Resources/Localizable.xcstrings', 'w', encoding='utf-8') as f:
    json.dump(xcstrings, f, indent=2, ensure_ascii=False)

print(f"Merged successfully. Total keys translated: {len(merged_dict)}")

# Clean up temp files
for i in range(4):
    os.remove(f'Tools/batch_{i}.json')
    if os.path.exists(f'Tools/batch_{i}_translated.json'):
        os.remove(f'Tools/batch_{i}_translated.json')
