#!/usr/bin/env python3
"""Unlock every base-game fighter in the Linux build's save, without earning them.

    deps/venv/bin/python scripts/linux/unlock_fighters.py [--save <system_data.bin>] [--dry-run]

The save is by default ~/.local/share/ssbu-recomp/userdata/save/save_data/system_data.bin (play.sh's). Layout from
WindowSmash's tools/unlock_all.py (github.com/SNO2207/WindowSmash, found on 11.0.0 and checked on 13.0.5); the same
tables were checked by hand on a 13.0.4 save (2026-10-21). Two tables, indexed by each fighter's save_no from
ui_chara_db.prc (0 Mario ... 73 Mii Gunner; 74-85 the DLC fighters, unlocked by build-linux/config/dlc.txt, not touched):
  FLAGS    8 bytes per fighter: [0] 1 = selectable, [1..3] challenger state, [4] the order fighters were first met
  RECORDS  the "joined the battle" milestone, 8 bytes: bits 0-11 year, 12-15 month, 16-20 day, 21-25 hour,
           26-31 minute, 32-37 second, 48-55 how (3), 63 set
A locked fighter gets what the game writes when one joins: the flag, the challenger state cleared, the next order number
and a milestone dated now (shown once at the next boot). A copy of the save goes to save_backups/ first.
"""
import argparse
import datetime
import os
import shutil
import struct
import subprocess

DATA = os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'ssbu-recomp')
SAVE = os.path.join(DATA, 'userdata', 'save', 'save_data', 'system_data.bin')
SAVE_SIZE, FORMAT = 0x5B4AF8, 0x1B
VERSIONS = {0xB000: '11.0.0', 0xD004: '13.0.4', 0xD005: '13.0.5'}   # offset 8: the game version that last wrote the save
FLAGS, RECORDS = 0x53FF40, 0x54FEA8
STARTERS = {0, 1, 2, 3, 5, 6, 7, 8}   # Mario, Donkey Kong, Link, Samus, Yoshi, Kirby, Fox, Pikachu
FIGHTERS = ['Mario', 'Donkey Kong', 'Link', 'Samus', 'Dark Samus', 'Yoshi', 'Kirby', 'Fox', 'Pikachu', 'Luigi',
            'Ness', 'Captain Falcon', 'Jigglypuff', 'Peach', 'Daisy', 'Bowser', 'Ice Climbers', 'Sheik', 'Zelda',
            'Dr. Mario', 'Pichu', 'Falco', 'Marth', 'Lucina', 'Young Link', 'Ganondorf', 'Mewtwo', 'Roy', 'Chrom',
            'Mr. Game & Watch', 'Meta Knight', 'Pit', 'Dark Pit', 'Zero Suit Samus', 'Wario', 'Snake', 'Ike',
            'Pokemon Trainer', 'Diddy Kong', 'Lucas', 'Sonic', 'King Dedede', 'Olimar', 'Lucario', 'R.O.B.',
            'Toon Link', 'Wolf', 'Villager', 'Mega Man', 'Wii Fit Trainer', 'Rosalina & Luma', 'Little Mac',
            'Greninja', 'Palutena', 'Pac-Man', 'Robin', 'Shulk', 'Bowser Jr.', 'Duck Hunt', 'Ryu', 'Ken', 'Cloud',
            'Corrin', 'Bayonetta', 'Richter', 'Inkling', 'Ridley', 'King K. Rool', 'Simon', 'Isabelle',
            'Incineroar', 'Mii Brawler', 'Mii Swordfighter', 'Mii Gunner']   # by save_no
HOW = 3


def record(t):
    return (t.year | t.month << 12 | t.day << 16 | t.hour << 21 | t.minute << 26 | t.second << 32
            | HOW << 48 | 1 << 63)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--save', default=SAVE, help='the save to change (default: %(default)s)')
    ap.add_argument('--dry-run', action='store_true', help='list what would be unlocked, change nothing')
    a = ap.parse_args()
    if subprocess.run(['pgrep', '-x', 'ssbu_native'], capture_output=True).returncode == 0:
        raise SystemExit('the game is running: close it first (it writes its save from memory and would undo this)')
    if not os.path.isfile(a.save):
        raise SystemExit('no save at %s: start the game once, reach the main menu, close it, then run this again' % a.save)

    data = bytearray(open(a.save, 'rb').read())
    size, fmt, version = struct.unpack_from('<III', data, 0)
    if len(data) != SAVE_SIZE or size != SAVE_SIZE or fmt != FORMAT or version not in VERSIONS:
        raise SystemExit('%s: not a system_data.bin of a known layout (%d bytes, format %#x, version %#x)'
                         % (a.save, len(data), fmt, version))
    flags = [data[FLAGS + 8 * n: FLAGS + 8 * n + 8] for n in range(len(FIGHTERS))]
    if any(flags[n][0] != 1 for n in STARTERS) or any(f[0] > 1 or any(f[5:]) for f in flags):
        raise SystemExit('the fighter table does not look as expected: nothing changed')
    for n, name in enumerate(FIGHTERS):
        old = struct.unpack_from('<Q', data, RECORDS + 8 * n)[0]
        if old and not old >> 63:
            raise SystemExit('unexpected milestone %#x for %s: nothing changed' % (old, name))
    print('save written by game version %s: %s' % (VERSIONS[version], a.save))

    rec = record(datetime.datetime.now())
    order = max(f[4] for f in flags)
    added = []
    for n, name in enumerate(FIGHTERS):
        if flags[n][0]:
            continue
        if not flags[n][4]:
            order += 1
        data[FLAGS + 8 * n: FLAGS + 8 * n + 5] = bytes([1, 0, 0, 0, flags[n][4] or order])
        if not struct.unpack_from('<Q', data, RECORDS + 8 * n)[0]:
            struct.pack_into('<Q', data, RECORDS + 8 * n, rec)
        added.append(name)
    if not added:
        print('every fighter is already unlocked')
        return
    print('%s %d: %s' % ('would unlock' if a.dry_run else 'unlocking', len(added), ', '.join(added)))
    if a.dry_run:
        return
    backups = os.path.join(DATA, 'save_backups')
    os.makedirs(backups, exist_ok=True)
    backup = os.path.join(backups, 'system_data.bin.before-unlock-' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S'))
    shutil.copy2(a.save, backup)
    with open(a.save + '.tmp', 'wb') as f:
        f.write(data)
    os.replace(a.save + '.tmp', a.save)
    print('saved; the previous save is %s (copy it back over system_data.bin to undo)' % backup)


if __name__ == '__main__':
    main()
