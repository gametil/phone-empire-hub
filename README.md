# Phone Empire — Auto Hub

A WindUI control panel for **Build a Phone Empire** that keeps your research lab
busy forever and handles the AFK chores.

- File: `PhoneEmpire.luau`
- Toggle the window: **Right Shift**
- Runs inside the Roblox client with an executor (built and tested with Real).

## What it does

### Research (the main job)

The game has **313 technologies**. Each one has a cost in RP, a required year,
and prerequisites. Only one lab slot exists unless you own the multi-research
pass.

The hub loops forever:

1. Reads your live company state from the server.
2. Works out which technologies are *unlocked* right now
   (prerequisites done, year reached, not already researched, not in the lab).
3. Sorts them with your chosen order (cheapest first by default).
4. Starts the first one you can afford, using a normal game remote call.
5. Waits for the slot to free up, then starts the next.

It never stops on its own. When the whole tree is done it simply reports
"nothing available" and keeps watching in case new tech appears.

Options:

- **Pick order** — cheapest first / most expensive / highest tier / tree order.
- **RP reserve** — never drop below this much RP.
- **Return to main screen** — closes the in-game panel after each action so you
  are sitting on the HUD instead of inside a menu.
- **Research the next tech now** — manual one-shot button.

### Money pipeline (the money machine)

The game pays you for launching new devices with high critic scores and good
marketing. The hub runs that loop for you:

1. Waits for the design team to be free.
2. Clones your **newest device**, fits the **best researched chassis**, and
   gives it the next name in the series.
3. Starts development at the previous device's price (adjustable multiplier).
4. The moment development hits 100%, it launches the device with the marketing
   campaign you picked.
5. Immediately starts the next design, forever.

| Feature | What it does |
| --- | --- |
| Auto design & start a project | Clones the newest design and starts development when the team is free |
| Auto launch finished devices | Launches the second development completes |
| Marketing campaign | None / Online ads / TV campaign / Global launch event / Best affordable |
| Launch price multiplier | 0.5x - 3x of the previous device's price |
| Cash buffer | Only starts a project when you have at least this many millions |
| Auto buy out rivals | Swallows the cheapest competitor you can afford (with a buffer) |
| Auto claim candy quests | Claims every candy quest the moment its goal is met |
| Auto repricing | Moves each active device's price towards the game's market value |
| Auto bankruptcy rescue | Spends the insurance rescue automatically if you go red |

"Best affordable" only picks a campaign that costs at most a third of your
cash, so there is always money left for the production run.

### AFK pack

| Feature | What it does |
| --- | --- |
| Anti-AFK | Virtual input pulse so Roblox does not idle you out |
| Keep game speed | Re-applies 1x / 2x / 4x / 8x if the game pauses time |
| Auto daily reward | Claims the daily gift as soon as it is ready |
| Auto RP boosts | Spends spare RP on lab quality / bug-fix boosts |
| Auto office upgrade | Buys the next office level when affordable |
| Auto expand regions | Opens the cheapest new market |
| Auto train staff | Turns cash into stars, one employee at a time |
| Auto hire | Hires the strongest candidate when a desk is free |
| Auto office party | Throws a party when team morale drops below 70 |

### Stats tab

Cash, RP, year and day, employees, devices, reputation, technologies done,
lab slots, research power per day, current goal, devices on sale, and a rolling
log of what the hub did.

## Notes

- Every action is the same remote the game's own buttons use, so it behaves
  like clicking them yourself. The server still validates everything.
- Time only advances while no game panel is open — that is why the hub works
  from the HUD and offers "return to main screen".
- Settings are saved to `PhoneEmpireHub/settings.json` when the executor
  supports `writefile`.

## Loading it again

Paste the contents of `PhoneEmpire.luau` into your executor and run it, or ask
for it to be reloaded through Real (`live-reload`).
