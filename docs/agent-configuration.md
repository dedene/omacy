# Agent-written screensaver configuration

Omacy deliberately uses two ordinary files as its public configuration surface. An agent,
editor, or script can drive the next screensaver effect without launching the app and
without a plugin or daemon:

- `~/.config/omacy/screensaver.txt` — non-empty UTF-8 ASCII art
- `~/.config/omacy/settings.json` — settings and the effect pool

Publish each file with a temporary file in the same directory followed by `mv`. The rename
prevents Omacy from observing a partly written file:

```sh
config_dir="$HOME/.config/omacy"
mkdir -p "$config_dir"

art_tmp=$(mktemp "$config_dir/.screensaver.txt.XXXXXX")
settings_tmp=$(mktemp "$config_dir/.settings.json.XXXXXX")

printf '  /\\_/\\\n ( o.o )\n  > ^ <\n' > "$art_tmp"
printf '%s\n' '{"effect":"random","effects":["beams","wipe"],"background":"#000000","fontSize":18,"asciiMode":"block","threshold":50,"invert":false}' > "$settings_tmp"

mv -f "$settings_tmp" "$config_dir/settings.json"
mv -f "$art_tmp" "$config_dir/screensaver.txt"
```

Omacy does not watch these files. The running saver reloads them at the next effect boundary;
the current animation finishes unchanged. The files are independent: if one is invalid,
Omacy can still accept the other and uses the current process's private last-good value or
bundled fallback for that file. Host and extension caches live in separate sandboxes and are
never shared.

## Settings contract

`effects` is the authoritative pool when present. It is a unique array of effect names; an
empty array normalizes to all effects. Omacy synchronizes the legacy `effect` field to this
pool: exactly one selected effect becomes that name, while any larger pool becomes `"random"`.
When `effects` is absent, legacy `effect` (`"random"` or one effect name) is imported as all
effects or a one-item pool. The currently supported names, sourced directly from the Rust
engine, are:

```text
beams binarypath blackhole bouncyballs bubbles burn colorshift crumble decrypt
errorcorrect expand fireworks highlight laseretch matrix middleout orbittingvolley
overflow pour print rain randomsequence rings scattered slice slide smoke spotlights
spray swarm sweep synthgrid thunderstorm unstable vhstape waves wipe
```

Other validated fields are `background` (`#RRGGBB`), positive `fontSize`, `asciiMode`
(`block` or `braille`), `threshold` (`0...100`), and boolean `invert`. Omacy's Art window uses
the same engine-provided catalog and schema as external writers.
