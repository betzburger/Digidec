import json
import os

with open('Sources/Resources/Localizable.xcstrings', 'r', encoding='utf-8') as f:
    xcstrings = json.load(f)

os.makedirs('Sources/Resources/en.lproj', exist_ok=True)
os.makedirs('Sources/Resources/de.lproj', exist_ok=True)

with open('Sources/Resources/en.lproj/Localizable.strings', 'w', encoding='utf-8') as f_en, \
     open('Sources/Resources/de.lproj/Localizable.strings', 'w', encoding='utf-8') as f_de:
     
    for key, val_obj in xcstrings['strings'].items():
        # en translation
        en_val = val_obj.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value', key)
        # Escape quotes and newlines
        def escape(s):
            return str(s).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            
        f_en.write(f'"{escape(key)}" = "{escape(en_val)}";\n')
        # de original
        f_de.write(f'"{escape(key)}" = "{escape(key)}";\n')

os.remove('Sources/Resources/Localizable.xcstrings')
print("Converted xcstrings to en.lproj and de.lproj Localizable.strings")
