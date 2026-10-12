# Supabase Edge Functions

Notification delivery status:

- `notification-dispatcher/` contains an opt-in FCM dispatcher for the durable
  notification outbox. It requires a service-role bearer and server-side
  Firebase service-account configuration; dispatch is disabled unless
  `NOTIFICATION_DISPATCH_ENABLED=true`. P31 tests cover provider payload,
  response classification, and synthetic signing; P65/P66 tests cover the HTTP
  handler against fake RPC/provider dependencies with network access denied.
  Neither set accepts deployed Edge Runtime behavior, database RPC persistence,
  or live provider delivery.
  Its HTTP `processed` count includes only jobs whose finish RPC returned
  `true`; `unconfirmed` counts claimed jobs whose finish result was false or
  could not be confirmed because of an RPC/transport error. An unconfirmed
  result does not prove the database transaction failed, and is not a delivery
  success metric.
- `notify-event-placeholder/` is a legacy non-delivery stub. It does not send
  notifications and must not be treated as the dispatcher.

Other placeholders for trusted server-side work:

- Admin moderation actions that require elevated privileges.
- Future external-calendar import jobs.

Implemented trusted boundaries:

- `university-email-verification` accepts only an authenticated JWT and the
  `issue`/`complete` actions. Full email addresses and one-time codes exist only
  during the request; PostgreSQL receives dedicated-secret HMAC-SHA256 values.
- The function requires `UNIVERSITY_VERIFICATION_HMAC_SECRET`,
  `UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_URL`, and
  `UNIVERSITY_VERIFICATION_EMAIL_WEBHOOK_TOKEN` as Edge secrets. The webhook is
  responsible for transactional delivery and must not log its `to` or `code`
  payload fields.
- Delivery failure calls the service-role-only invalidation RPC. The function
  returns masked email data and never returns an OTP, HMAC, service-role key, or
  provider diagnostic.

Do not put service role keys in mobile code or browser-rendered admin code. Use Supabase function secrets or deployment environment variables.
