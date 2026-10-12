# TalkBack evidence record

> Store the completed copy outside the repository. Use synthetic data only. Do
> not record raw device serials, Android IDs, account identifiers, notification
> bodies, personal schedules, raw adb output, or unredacted logs. Only a human
> observer may replace `MANUAL REQUIRED` with a verdict.

## Run identity

| Field | Value |
|---|---|
| Source SHA (40 hex) | MANUAL REQUIRED |
| Environment (`debug` or `staging`) | MANUAL REQUIRED |
| Package/version code/version name | MANUAL REQUIRED |
| Inventory JSON filename | MANUAL REQUIRED |
| Manufacturer/model | MANUAL REQUIRED |
| Android/API level | MANUAL REQUIRED |
| Build fingerprint SHA-256 | MANUAL REQUIRED |
| Display/font scale | MANUAL REQUIRED |
| Initial theme/orientation | MANUAL REQUIRED |
| Observation UTC start/end | MANUAL REQUIRED |

## Configuration results

| Configuration | Status | Privacy-safe evidence reference / note |
|---|---|---|
| Default portrait traversal | MANUAL REQUIRED | |
| 200% font / largest practical text | MANUAL REQUIRED | |
| Landscape | MANUAL REQUIRED | |
| Dark theme | MANUAL REQUIRED | |
| Locked and unlocked alarm surfaces | MANUAL REQUIRED | |

## Screen results

For every screen, assess forward/back traversal order, accessible name, role,
state/value, available actions, focus after navigation/dialog/error, 48 dp-class
control reachability, large-text reflow, and information conveyed without color.

| Screen/surface | Status | Evidence reference | Finding / reproduction |
|---|---|---|---|
| Today | MANUAL REQUIRED | | |
| Timetable day/week | MANUAL REQUIRED | | |
| Assignments | MANUAL REQUIRED | | |
| Exams | MANUAL REQUIRED | | |
| Calendar | MANUAL REQUIRED | | |
| Morning-alarm settings | MANUAL REQUIRED | | |
| Native ringing activity | MANUAL REQUIRED | | |
| Alarm notification / lock screen | MANUAL REQUIRED | | |
| Document import/review/editor | MANUAL REQUIRED | | |
| Settings/account/legal/support | MANUAL REQUIRED | | |
| Android home-screen widget | MANUAL REQUIRED | | |

## Focused observations

| Check | Status | Evidence reference / note |
|---|---|---|
| Assignment edit controls announce the item title | MANUAL REQUIRED | |
| Candidate validation error is announced once when it appears | MANUAL REQUIRED | |
| Alarm loading and failure states are announced | MANUAL REQUIRED | |
| Permission explanations receive focus before system settings | MANUAL REQUIRED | |
| Stop, Snooze, and Today are distinct and ordered | MANUAL REQUIRED | |
| Lock-screen alarm contains no private schedule detail | MANUAL REQUIRED | |
| Dialog dismissal returns focus predictably | MANUAL REQUIRED | |
| No essential action is clipped/unreachable at 200% | MANUAL REQUIRED | |
| Landscape reading/focus order matches the visual order | MANUAL REQUIRED | |
| Dark-theme states remain distinguishable without color alone | MANUAL REQUIRED | |

## Failures and blocks

Record only concise synthetic reproduction steps. Reference a separately approved,
redacted artifact if needed; do not paste raw logs.

| ID | Status (`FAIL`/`BLOCKED`) | Expected | Observed | Reproduction / safe reference |
|---|---|---|---|---|
| | MANUAL REQUIRED | | | |

## Closeout

| Item | Status | Note |
|---|---|---|
| TalkBack restored to original state | MANUAL REQUIRED | |
| Font/display scale restored | MANUAL REQUIRED | |
| Theme/orientation restored | MANUAL REQUIRED | |
| Alarm permissions and battery settings restored | MANUAL REQUIRED | |
| Synthetic data/account cleanup completed under approved plan | MANUAL REQUIRED | |

Overall human verdict: **MANUAL REQUIRED**
