BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(6);
SELECT gen_random_uuid() AS user_id \gset
SELECT gen_random_uuid() AS installation_id \gset

INSERT INTO auth.users(id) VALUES (:'user_id');
SELECT set_config('request.jwt.claim.sub', :'user_id', true) AS claim_sub \gset
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE generation_one ON COMMIT DROP AS
SELECT * FROM public.register_notification_device(
 :'installation_id',1,'android','synthetic-generation-token-0001');
SELECT extensions.is((SELECT binding_generation FROM generation_one),1::bigint,
 'first installation generation is accepted');
SELECT extensions.is((SELECT accepted FROM public.register_notification_device(
 :'installation_id',1,'android','synthetic-stale-token-0000')),false,
 'duplicate client generation is ignored');
CREATE TEMP TABLE generation_two ON COMMIT DROP AS
SELECT * FROM public.register_notification_device(
 :'installation_id',2,'android','synthetic-generation-token-0002');
SELECT extensions.is((SELECT binding_generation FROM generation_two),2::bigint,
 'new client generation rotates the binding generation');
SELECT extensions.is(public.revoke_notification_device(:'installation_id',1,1),false,
 'stale revoke cannot disable the newer token binding');
SELECT extensions.is(public.revoke_notification_device(:'installation_id',2,2),true,
 'current client and binding generation can revoke the installation');
RESET ROLE;
SELECT extensions.ok((SELECT NOT enabled FROM private.notification_installation_bindings
 WHERE installation_id=:'installation_id') AND EXISTS (
 SELECT 1 FROM public.device_tokens t JOIN private.notification_installation_bindings b
   ON b.public_token_id=t.id
 WHERE b.installation_id=:'installation_id' AND t.revoked_at IS NOT NULL),
 'current revoke disables private delivery binding and revokes public token projection');
SELECT * FROM extensions.finish();
ROLLBACK;
