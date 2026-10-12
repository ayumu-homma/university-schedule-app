# Project state

The optional [Spatial Week source experiment](SPATIAL_WEEK_EXPERIMENT.md) has passed functional acceptance as `3D_EXPERIMENTAL` on source branch `codex/v1.2-spatial-week`. The normal 2D timetable remains the default, controlled by `APP_ENABLE_SPATIAL_WEEK=false`. The package remains `1.1.0+2`; this is not a stable v1.2 release. Emulator interaction and Drift read-only/context-fence checks passed. Emulator frame/PSS diagnostics do not establish a consistent advantage; iOS, physical-device and human usability acceptance remain unmeasured. See [TESTING](TESTING.md#spatial-week-25d-source-experiment).

v1.1.0 is the academic UI source release following immutable v1.0.0. Today, readable timetable selection, assignment/exam navigation and shared responsive/accessibility behavior are implemented; final acceptance is recorded in TESTING. Public history begins at v1.0; historical development logs and private fixtures are not distributed. The mobile app is 1.1.0+2; shared_domain and admin retain their independent internal package version 0.1.0.

See [TESTING](TESTING.md) for current measured checks and historical evidence, [CHANGELOG](../CHANGELOG.md) for source changes, and [ROADMAP](../ROADMAP.md) for UI/UX, evaluated 3D use, and real-user validation. Hosted services, physical/OEM Android, iOS, real providers and stores require separate acceptance. Public deployment workflow jobs are disabled.

See [UX research](UX_RESEARCH_V1_1.md) and [design system](UX_DESIGN_SYSTEM.md) for source-grounded design and editable own wireframes. Official-document research and local synthetic tests are distinct from real-user usability acceptance. Spatial Week is an opt-in experiment after v1.1 acceptance; the 2D journey remains the default.
