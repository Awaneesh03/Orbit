# Orbit Pet characters (Rive): architecture and character contract

Status (2026-11-14, zero-cost): **shipping two free CC0 characters**, the
Tabby (cat) and the Shiba (dog) by pzUH, played as frame strips; the Tabby is
the default. Rive stays fully supported for any free Rive character. Orbit's
illustrated vector pet remains selectable ("Orbit illustrated": coats and
photo colours) and is the fallback for every failure. **Orbit's budget is
permanently $0**: nothing here is bought, subscribed to or commissioned.

## Runtime

- `rive-ios` **6.29.0** (pinned, exact; released 2026-10-30), MIT licence.
  Binary `RiveRuntime.xcframework`; builds with Command Line Tools
  (verified). macOS slice: 11 MB universal binary, embedded by
  `scripts/run.sh` into `Orbit.app/Contents/Frameworks` and ad-hoc signed
  (14 MB on disk). Rpaths: app `@executable_path/../Frameworks`, tests
  `@loader_path/../../..`.
- API used: `RiveFile(data:loadCdn: false)` (no network), `RiveViewModel`
  (state machine, `setInput`, `triggerInput`, play/pause), `RiveView`
  (Metal). The legacy view-model API is deprecated in favour of Rive's
  concurrency runtime but supported in 6.29; moving is contained in `RivePetSkin`.
- Not in the macOS 6.29 binary: the CoreGraphics renderer, so **Rive frames
  can't be rendered offscreen**; screenshots need Screen Recording or your eyes.

## Architecture

```
PetModel (states, timers, behaviour) ─► PetCharacter ─► PetRig (vector, always present)
                                                          │ attach(skin)
                                                          ▼
                                                    RivePetSkin (one per rig: desktop, notch)
                                                          │ inputs per manifest
                                                          ▼
                                   PetCharacterLibrary (one parsed RiveFile per character, released on switch)
```

- `PetRig` keeps all state; with a skin it hides its vector figure and
  forwards state changes, fidgets (`fidget`), gestures (`lookAround`,
  `stretch`, `sit`), clicks (`click`), agent cues (`activity`, `attention`,
  `happy` = finished, `concerned` = failed) and mood (`mood.<value>`).
  Detaching is instant.
- Desktop window and notch companion show the same character; clicks and
  drags still go to Orbit's views. Facing mirrors per `facesRight`.
- **Energy rule**: continuous rendering only while walking, running or
  dragged (30 fps); a change or action plays a 2.5 s burst, then the
  character holds its frame and MetalKit's display link stops. Hidden or
  Reduce Motion: nothing renders. Skins are created paused.
- **Fallback**: none chosen, not found, missing/oversized/corrupt file,
  missing artboard or state machine → the vector pet, logged.

## Character folder

`Resources/Pets/<id>/` (bundled) or `~/Library/Application Support/Orbit/Pets/<id>/`:
`character.riv` (≤ 20 MB, everything embedded, no CDN), `character.json`
(`PetCharacterManifest`: id, name, species, version, file, artboard,
stateMachine, production, facesRight, licence {type, creator, source,
attribution, commercialUse, redistribution, modification, cost}, `states`
and `actions` → inputs), `LICENSE.md`. The user's choice stores only the id,
so updated files never reset customisation.

## Bundled characters (free)

| Character | Source | Licence | Cost | Clips |
|---|---|---|---|---|
| Tabby (cat), `pzuh-cat` | "Cat & Dog Free Sprites" by pzUH, OpenGameArt | CC0 1.0 | free | idle 10, walk 10, run 8, jump 8, fall 8, sit 3, sleep 1 (derived) |
| Shiba (dog), `pzuh-dog` | same pack | CC0 1.0 | free | same |

Built by `scripts/build-pet-atlases.swift` (one shared crop per animal, 200 px
tall, one strip per clip; sleep frame derived by closing the Slide pose's
mouth). ~0.9 MB and 1.2 MB on disk; ~7.3 MB decoded per character, shared by
desktop and notch. State → clip: idle → idle, walking → walk, running → run,
sleeping → sleep, dragged → fall (dangling), playful → jump. Actions: click,
happy (agent finished), attention → jump; fidget, look around, activity →
idle; stretch, sit → sit (held ~2.5 s). No clip for `concerned`: nothing is
faked. The art's own colours are fixed; coats and photo colours apply to the
illustrated pet. Sprite manifests need empty `states`/`actions` keys.

`SpritePetSkin` energy rule: loops only while walking, running or dragged;
other states are still frames; reactions play once as self-removing
animations (no timers). Measured live: settled 0.0 % CPU.

## Character contract (for any future free character)

One artboard, one state machine named **`Pet`**, side view facing right,
standing on the bottom edge, about 600 × 500, everything embedded.

| Input | Type | Orbit drives it when |
|---|---|---|
| `state` | number | 0 idle · 1 walk · 2 run · 3 sleep · 4 dragged · 5 playful (blended transitions) |
| `sit` | bool | idle gesture: sits and watches |
| `click` / `doubleClick` | trigger | clicks |
| `pet` | trigger | stroking (purr / tail wag) |
| `stretch`, `lookAround`, `wake` | trigger | idle gestures; sleep → sit → idle |
| `happy` / `concerned` / `attention` | trigger | an agent finished / failed / needs you |

Blinking and breathing on internal timers; tail and ears with secondary
motion; idle that **settles** (no endless loop, so held frames cost 0 %);
a sleeping pose that reads in a still frame; cat and dog by the same artist.

## Test character

`Tests/OrbitTests/Fixtures/Pets/test-interactive-dog`: "Interactive Dog" by
jouri, CC BY 4.0 (Rive Marketplace), unmodified, tests only, not bundled.
