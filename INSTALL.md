# Installation — step by step

Getting the files from GitHub onto your machine and into MetaTrader 5.

For what to do **after** installing — compile order, which tests to run and in
what order — see `COMPILE_ORDER.md`.

**Nothing here has been compiled.** Expect the first compile to produce errors.
That is what step 6 is for.

---

## What you are installing

| Count | What | Goes to |
|---|---|---|
| 23 | `.mqh` module headers | `MQL5/Include/SEA/` |
| 1 | `SEA.mq5` — the Expert Advisor | `MQL5/Experts/SEA/` |
| 8 | `.mq5` test scripts | `MQL5/Scripts/SEA/` |

---

## Step 1 — Download the files

Pick whichever you are comfortable with.

### Option A — Download a ZIP (no git needed)

1. Open this URL in a browser:

   ```
   https://github.com/Callmeteo05/boomcrash-remote-control/tree/claude/mql5-ea-project-setup-968a0t
   ```

2. Click the green **Code** button → **Download ZIP**.

3. Extract the ZIP somewhere you can find it — your Desktop is fine. You will
   get a folder named something like
   `boomcrash-remote-control-claude-mql5-ea-project-setup-968a0t`.

**Make sure the branch selector says `claude/mql5-ea-project-setup-968a0t`
before you download.** If it says `main` you will get an empty project — all
the code is on the branch.

### Option B — Clone with git

```
git clone https://github.com/Callmeteo05/boomcrash-remote-control.git
cd boomcrash-remote-control
git checkout claude/mql5-ea-project-setup-968a0t
```

Later, to pull down fixes:

```
git pull origin claude/mql5-ea-project-setup-968a0t
```

---

## Step 2 — Find your MetaTrader data folder

Do **not** guess this path, and do **not** use the folder where MetaTrader was
installed (`C:\Program Files\...`). They are different folders, and files put
in the install folder will not be seen.

1. Open MetaTrader 5.
2. Menu: **File → Open Data Folder**.
3. A file explorer window opens. Inside it is a folder called `MQL5`.

Leave that window open — you need it in step 3.

The real path looks roughly like:

```
C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\<long string of letters and numbers>\MQL5
```

That long string differs per installation, which is exactly why you open it
through the menu instead of typing it.

---

## Step 3 — Create the three SEA folders

Inside the `MQL5` folder from step 2, you will already see `Include`, `Experts`
and `Scripts`. Create a new folder named `SEA` inside each:

```
MQL5\Include\SEA\
MQL5\Experts\SEA\
MQL5\Scripts\SEA\
```

Spelling and capitalisation matter — the `#include <SEA/...>` lines in the code
look for exactly `SEA`.

---

## Step 4 — Copy the files across

From the folder you downloaded in step 1, into the folders you just made:

| Copy this | Into this |
|---|---|
| everything inside `Include/SEA/` (23 `.mqh` files) | `MQL5\Include\SEA\` |
| `Experts/SEA/SEA.mq5` | `MQL5\Experts\SEA\` |
| everything inside `Scripts/SEA/` (8 `.mq5` files) | `MQL5\Scripts\SEA\` |

Copy the **files**, not the folders. You want
`MQL5\Include\SEA\CSymbolSpec.mqh`, not
`MQL5\Include\SEA\SEA\CSymbolSpec.mqh`.

Do **not** copy:

- `Files/` — the EA writes into the terminal's own `MQL5\Files\` at runtime
- `CLAUDE.md`, `COMPILE_ORDER.md`, `INSTALL.md`, `config.json` — documentation
  and unrelated files, MetaEditor has no use for them

### Check it worked

This exact file must now exist:

```
MQL5\Include\SEA\CSymbolSpec.mqh
```

If it does not, the compile will fail with `cannot open source file` on every
single file. Fix the paths before going further.

---

## Step 5 — Open MetaEditor and refresh

1. Back in MetaTrader, press **F4** (or **Tools → MetaQuotes Language Editor**).
2. In the **Navigator** panel on the left, right-click the top item and choose
   **Refresh**.
3. You should now see `SEA` folders under Include, Experts and Scripts.

If the folders do not appear after a refresh, the files went to the wrong
place. Go back to step 2 — the most common cause is using the *installation*
folder instead of the *data* folder.

---

## Step 6 — Compile

**Stop here and switch to `COMPILE_ORDER.md`.**

The important part, and the reason there is a separate document: compile the
23 headers **one at a time in the listed order**, not `SEA.mq5` first. `SEA.mq5`
includes all 22 other headers, so one bad header produces hundreds of cascading
errors that all point at the wrong file.

Send me the first errors you get rather than guessing at fixes — several of
these modules interlock, and a wrong fix in one place moves the error somewhere
less obvious.

---

## Step 7 — Enable trading (only after the tests pass)

Do not do this until `COMPILE_ORDER.md` step 7 is clean.

1. **Use a demo account.** `Test_RiskHalt` refuses to run on a live account,
   and the drawdown halt has never fired in anger.
2. In MetaTrader: **Tools → Options → Expert Advisors**, tick
   *Allow algorithmic trading*.
3. Click the **AutoTrading** button in the toolbar so it is green.
4. Drag `SEA` from the Navigator onto a chart.
5. In the dialog, **Common** tab: tick *Allow Algo Trading*.
6. **Inputs** tab: set `InpMagicNumber`, and set `InpVerbose = true` for the
   first session.
7. Click OK. A smiley face in the top-right of the chart means the EA is
   running.

Watch the **Experts** tab at the bottom of MetaTrader. At startup you should
see the universe size, how many symbols came out tradeable, and — if most did
not — a warning naming the constraint responsible.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot open source file 'SEA/SEA_Common.mqh'` | Files are not under `MQL5\Include\SEA\` | Redo steps 2–4. Check the exact file path from step 4 |
| SEA folders do not appear in Navigator | Wrong folder, or no refresh | Right-click Navigator → Refresh. If still missing, you used the install folder rather than the data folder |
| Downloaded ZIP has no `Include` folder | Downloaded `main` instead of the branch | Redo step 1 with the branch selected |
| Sad face on the chart instead of a smiley | AutoTrading off, or *Allow Algo Trading* unticked | Step 7 items 3 and 5 |
| EA logs a hard halt at startup and will not trade | A persisted drawdown flag, or leftover state from `Test_RiskHalt` | Run `Test_RiskHalt` with `InpPhase = 3` to clear it. This is deliberate — the kill switch is meant to survive restarts |
| `Test_Repaint` aborts saying it needs more bars | History not downloaded | Scroll the chart back until bars load, then re-run |
