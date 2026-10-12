# Academic UI design system

The v1.1 composition follows the [source-backed UX research](UX_RESEARCH_V1_1.md) and [editable synthetic wireframes](ux/wireframes.svg). The [editable Figma research board](https://www.figma.com/design/daI6omgWxm0HCrxRalX5we?node-id=2-26) contains six current/proposed schematic frames, reusable navigation and23 variables. These are design proposals, not device acceptance evidence.

## Visual rules

The Flutter implementation is the visual source of truth: [tokens](../apps/mobile/lib/app/theme/app_tokens.dart) and [theme](../apps/mobile/lib/app/theme/app_theme.dart). Spacing uses4/8/12/16/24/32/48dp; controls use at least48dp touch regions; radii8/12/20dp; readable content caps at840dp (forms680dp). Body text16sp with14sp supporting labels scales with the system. Compact week cells may abbreviate long text; selection reveals the full course title, room and time without shrinking essential detail. Category/status colors always have text or icons. Light surfaces are neutral white/gray, and dark mode preserves semantic foreground contrast.

## Shared components and behavior

- `MvpScaffold`: persistent five destinations, tablet navigation rail for width>=840dp and adequate height, guarded navigation, settings and quick-add; low landscape retains the bottom bar.
- `ResponsiveContent`: centered, bounded layouts with consistent phone/tablet padding.
- `TodayAtAGlance`: date, current/next class and route counts from the same daily projection as Home; full non-empty agenda and recoverable submission below. Empty categories stay quiet; a truly empty local day has add actions. Group availability/error remains distinct.
- `AcademicModeSwitch`: explicit assignments/exams modes over existing routes; count scope is explained. Existing date/course filters, status changes, in-flight feedback and Undo retain their data contracts.
- Timetable selection sheet: full Japanese title/room/weekday/period/time and associated workload; an explicit action opens normal course detail. Separate management offers existing edit/delete paths.
- Owner transitions immediately remove captured course metadata from both sheets and revalidate every action. Missing configured period times are labeled unset consistently in the grid and details. These local UI guards supplement existing owner-scoped storage and server authorization.
- `AppSectionHeader`, `EmptyState`, badges and Material fields/buttons retain consistent hierarchy on calendar, sharing, groups, settings and onboarding.

Motion uses120/220/320ms tokens for brief feedback. `AccessiblePageTransitionsBuilder` removes route effects when the OS requests reduced motion; supported platforms keep their native-style transition otherwise. Sheets honor the same setting. Reading and completing a schedule never require animation.

## Acceptance and limits

Required scenarios:360/412dp, tablet and landscape,200%system text, long Japanese titles/rooms, light/dark, keyboard insets, safe areas,48dp controls, meaningful semantics and reduced motion. Regression gates cover local persistence, account isolation, timetable add/detail/management, deadlines/exams, submission failure/double taps/Undo and alarm-to-Today routing. Measured results and missing device/service acceptance belong in [TESTING](TESTING.md); this design document does not claim them passed.

The 2D academic journey remains complete independently of optional spatial experiments. No migration, auth, RLS, sync, widget or notification contract is changed by this visual design.
