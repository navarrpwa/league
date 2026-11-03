# League Auction PWA

Player registration, team logins, an admin panel, live bidding and an animated projector screen.
The whole interface is in `index.html`. The backend is Supabase. It deploys to GitHub Pages with no build step.

## Files

| File | Purpose |
|---|---|
| `index.html` | The complete frontend: all HTML, CSS, JavaScript, routes and animations |
| `manifest.webmanifest`, `sw.js`, `icons/` | PWA support. Browsers require these to be separate files, so they cannot go inside `index.html` |
| `supabase/setup_all.sql` | The full database setup in one file, for the SQL editor |
| `supabase/reset_before_setup.sql` | Deletes an earlier setup. Use only before re-running the setup |
| `supabase/migrations/` | The same SQL split into schema, functions and security |
| `tests/` | Database and browser tests. Not needed for deployment |

## Deployment

1. **Create a Supabase project** at supabase.com.
2. **Run the database setup.** In SQL Editor, paste all of `supabase/setup_all.sql` and run it once. This also creates the storage bucket, its policies and the realtime publication.
3. **Replacing an earlier setup?** If you already ran an older `setup_all.sql` in this project, run `supabase/reset_before_setup.sql` first, then `setup_all.sql`. The reset deletes all league data, so never run it once real data exists.
4. **Create your admin.** Run this in SQL Editor with your own username, password and league name:
   ```sql
   select private.bootstrap_admin('admin', 'your-strong-password', 'Your League Name');
   ```
   This can only run from the SQL editor. The app has no way to grant admin rights. Run it again with another username to add an admin, or with the same username to reset a forgotten admin password.
5. **Sign in** at `#/login`. Create teams, then create each team's username and password under Team logins. No emails are needed or sent, and Supabase Auth is not used.
6. **Connect the app.** In Project Settings > API Keys, copy the project URL and the publishable key into the `CONFIG` block near the top of the script in `index.html`. Never use the service-role or secret key.
7. **Create a GitHub repository** and add `index.html`, `manifest.webmanifest`, `sw.js` and `icons/`. Leave `tests/` and `supabase/` out if you prefer. The app does not load them.
8. **Enable GitHub Pages.** In Settings > Pages, set Source to "Deploy from a branch", then choose `main` and `/ (root)`. All paths are relative, so a project URL under a repository name works.
9. **Test before the event** with the checklist below.
10. **On auction day**, open `#/auction/live` on the display computer and click once to enable sound and full screen. Run `#/admin/live` from a separate device.

### Pages

| Route | Who | What |
|---|---|---|
| `#/` | Everyone | League home page |
| `#/register` | Everyone | Player registration |
| `#/login` | Teams, admins | Sign in |
| `#/team` | Team logins | Budget, squad and BID button |
| `#/admin/...` | Admins | All admin modules, including `#/admin/live` |
| `#/auction/live` | Public, read-only | Projector screen |

### Pre-event checklist on your real project

1. Register a player from a phone using the camera, then approve them.
2. Create two teams and their logins, and sign in as each on separate devices.
3. Open the projector. Run a player through introduction, bidding, last call and SOLD. Confirm that the projector and team screens change without a refresh.
4. Undo that sale and confirm the points return.
5. Turn Wi-Fi off on a team phone. The warning must appear and BID must disable. Turn it back on and it must recover.
6. Listen to the sound on the actual venue speakers.

## Architecture

```
 Projector (read-only)     Team phones          Admin control room
         |                      |                       |
         |   single index.html served by GitHub Pages   |
         +----------------------+-----------------------+
                                |
              1. Actions and reads go through database functions (RPC)
              2. Realtime announces "session version changed"
              3. Each client then fetches the full state from the server
                                |
                         Supabase PostgreSQL
           auction functions | row level security | audit log
```

**The server is the only source of truth.** Every state change raises `auction_sessions.version`. Realtime carries only that signal, and clients then call `get_auction_state()`. A missed or out-of-order message therefore cannot leave a screen wrong. Clients also poll every 6 seconds, or every 2 seconds when realtime is down, and they ignore any response older than what they already have.

**Bids cannot conflict.** Every bid, sale and undo first locks the auction session row, so they run strictly one at a time. A bid must equal the exact next valid price, so when two teams press at the same moment, one is accepted and the other is told the price moved. A unique index also rejects two live bids at the same price, and another rejects two standing sales of one player.

**Points come from a ledger.** `team_budgets.spent` is recalculated from standing sales after each sale or undo. Nobody can edit it directly.

### Auction stages

```
idle -> introduction -> bidding -> last_call -> closed -> sold or unsold -> idle
                           ^           |          |
                           +-- reopen -+----------+
```

Session status is separate: `not_started`, `live`, `paused` or `ended`. Pausing freezes the countdown and blocks bids and sales.

### How these rules behave

These are decisions the brief left open. They are easy to change if your league prefers otherwise.

- **Timers never sell.** When the normal countdown reaches zero, bidding stays open and the screen shows "Awaiting auctioneer". When the last-call countdown reaches zero, new bids are refused, but only the admin can sell or reopen.
- **A bid during last call** is accepted and restarts the last-call countdown.
- **SOLD needs last call or closed bidding first**, followed by a confirmation dialog.
- **Fixed increments.** Teams bid only the next valid price, with no jump bids. Increments can be set per player and changed mid-bidding.
- **A team's only limits** are its remaining points and squad slots. No points are reserved for filling remaining squad slots, so a team can spend its whole budget on one player.
- **Marking unsold or skipping** cancels that player's bids. An undone sale returns the player to the queue, and bidding restarts from the base price.
- **Admin-entered bids** cover a team whose device has failed. They are recorded in the audit log.
- **Team budgets are public.** Spent and remaining points appear on the projector and to all teams. Sales are public too. Logins and phone numbers stay private.

### Statistics bar

- **Registered:** every registration except rejected ones.
- **Remaining:** players waiting or skipped, plus the player on the block. Excludes sold, unsold, withdrawn and unapproved players.
- **Progress:** (sold + unsold) divided by all approved players still in the pool.

## Database

| Table | Holds |
|---|---|
| `profiles`, `user_sessions`, `login_attempts` | Usernames, password hashes and roles; sessions; failed sign-in counts. None is readable through the API |
| `tournaments`, `tournament_settings` | League, branding, timers and defaults |
| `players` | Public player details |
| `player_contacts` | Phone numbers, kept apart and readable only by admins |
| `teams`, `team_memberships`, `team_budgets` | Teams, their logins, budgets and squad limits |
| `auction_sessions` | Live status, stage, countdown and version |
| `auction_players` | Each player's lot: base price, increment, highest bid, status |
| `bids` | Accepted bids, including cancelled ones |
| `player_sales`, `team_squads` | Sales, including undone ones, and current squads |
| `auction_events` | Timeline, including rejected bids |
| `admin_audit_logs` | Who did what. Append-only, enforced by a trigger |
| `announcements` | Notices for teams and the projector |

## Security

- The browser holds only the publishable key. Hiding admin pages is not what protects them: each admin function checks the caller's role on the server.
- API users have **no direct write access to any table**. All writes go through database functions that validate them.
- Without a session, a caller can only read the live state, register a player and sign in. All other functions refuse them.
- **Logins are the app's own.** Usernames and bcrypt password hashes are in `profiles`, which the API cannot read. Sign-in returns a random 30-day session token, and only its SHA-256 hash is stored. The browser sends it in an `x-league-session` header on each request.
- After 10 wrong passwords, a username locks for one minute. Changing or resetting a password signs out other devices.
- Anyone can upload images to the bucket's known folders, limited to 3 MB and JPG, PNG or WebP, because Storage can't see the app's own logins. Files can't be overwritten or deleted through the API, and only the checked functions can attach a file to a player, team or tournament.

### Known limits

- **Registration is public with no rate limit.** Someone could submit junk entries, which wait in the pending list, or upload junk photos. The form also reveals whether a phone number is already registered, which duplicate prevention requires. If this becomes a problem, turn on Supabase's CAPTCHA support and add a check to the registration function.
- **Approved players' name, photo, age, position and description are publicly readable** through the API, not only the fields shown on screen.
- **One active tournament per project.** Use a new Supabase project for each new season.
- **Sign-in tokens are kept in browser storage**, so a script injected into the page could read them. All displayed values are escaped to prevent that.
- **There is no self-service password reset**, because accounts have no email. Admins reset team passwords, and the SQL editor resets admin passwords.
- **Old unattached images stay in storage.** Clean them up in the Supabase dashboard if needed.
- **Phone numbers are matched by digits only**, so `+974 5555 1234` and `55551234` count as different numbers.

## Implementation phases

All phases are complete in this delivery.

1. Schema, security, and auction functions
2. Registration, sign-in and approval
3. Teams, logins, budgets and settings
4. Live engine and control room
5. Team dashboard and bidding
6. Projector animations and sound
7. Reports, CSV import and export, PWA, and testing

## Tests

```
cd tests && npm install && npx playwright install chromium
npm run test:db    # 82 checks on real PostgreSQL using the same migrations
npm run test:e2e   # 43 browser checks across registration, admin, two teams and the projector
```

The tests use a real PostgreSQL server, so database rules, permissions and concurrency are exercised for real. Supabase's REST, Storage and Realtime services are **stand-ins** in `tests/gateway.js`, so the checklist above still needs running on your actual project.
