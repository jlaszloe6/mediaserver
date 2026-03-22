#!/bin/bash
# Custom init script for linuxserver/transmission
# Applies speed limit env vars to settings.json on every container start
#
# Mounted into /custom-cont-init.d/ via docker-compose

SETTINGS="/config/settings.json"

[ ! -f "$SETTINGS" ] && exit 0

python3 -c "
import json, os

with open('$SETTINGS') as f:
    s = json.load(f)

env_map = {
    'TRANSMISSION_SPEED_LIMIT_DOWN_ENABLED': ('speed-limit-down-enabled', lambda v: v.lower() == 'true'),
    'TRANSMISSION_SPEED_LIMIT_DOWN': ('speed-limit-down', int),
    'TRANSMISSION_SPEED_LIMIT_UP_ENABLED': ('speed-limit-up-enabled', lambda v: v.lower() == 'true'),
    'TRANSMISSION_SPEED_LIMIT_UP': ('speed-limit-up', int),
}

changed = False
for env_var, (key, convert) in env_map.items():
    val = os.environ.get(env_var)
    if val is not None:
        new_val = convert(val)
        if s.get(key) != new_val:
            s[key] = new_val
            changed = True
            print(f'  {key} = {new_val}')

if changed:
    with open('$SETTINGS', 'w') as f:
        json.dump(s, f, indent=4, sort_keys=True)
    print('Speed limits updated.')
else:
    print('Speed limits already match env vars.')
"
