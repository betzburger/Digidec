import json
import os
import math

with open('Sources/Resources/Localizable.xcstrings', 'r', encoding='utf-8') as f:
    xcstrings = json.load(f)

keys = list(xcstrings['strings'].keys())
batch_size = math.ceil(len(keys) / 4)

for i in range(4):
    start = i * batch_size
    end = min((i + 1) * batch_size, len(keys))
    batch_keys = keys[start:end]
    
    batch_dict = {k: "" for k in batch_keys}
    
    with open(f'Tools/batch_{i}.json', 'w', encoding='utf-8') as f:
        json.dump(batch_dict, f, indent=2, ensure_ascii=False)
    print(f"Created batch_{i}.json with {len(batch_keys)} items")
