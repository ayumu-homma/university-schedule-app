param(
  [string]$Container = 'supabase_db_phase16_fresh_20260922',
  [string]$Database = 'gpt6_safety_20260923'
)
$ErrorActionPreference = 'Stop'
$ownerId = [guid]::NewGuid().ToString()
$inviteeId = [guid]::NewGuid().ToString()
$groupId = [guid]::NewGuid().ToString()
$runId = $groupId.Replace('-', '')
$lockApp = "invite-lock-$runId"
$acceptApp = "invite-accept-$runId"
$tempDir = Join-Path $env:TEMP "targeted-invite-race-$($groupId.Replace('-', ''))"
$resolvedTempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedTempDir = [System.IO.Path]::GetFullPath($tempDir)
if (-not $resolvedTempDir.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedTempDir) -ne "targeted-invite-race-$($groupId.Replace('-', ''))") {
  throw 'temporary test directory escaped its exact per-run temp path'
}
New-Item -ItemType Directory -Path $tempDir | Out-Null
function Write-Sql([string]$Name, [string]$Sql) {
  $path = Join-Path $tempDir $Name
  Set-Content -LiteralPath $path -Value $Sql -Encoding utf8
  $containerPath = "/tmp/$Name"
  & docker cp $path "${Container}:$containerPath" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "docker cp failed for $Name" }
  return $containerPath
}
function Start-Psql([string]$SqlPath, [string]$OutputPath, [string]$ApplicationName) {
  return Start-Process -FilePath 'docker.exe' -ArgumentList @(
    'exec', '-e', "PGAPPNAME=$ApplicationName", $Container, 'psql', '-U', 'supabase_admin', '-d', $Database,
    '-X', '-v', 'ON_ERROR_STOP=1', '-f', $SqlPath
  ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError "$OutputPath.err"
}
try {
  $setup = @"
insert into auth.users(id) values ('$ownerId'),('$inviteeId');
insert into public.profiles(user_id,display_name) values ('$ownerId','Synthetic invite owner'),('$inviteeId','Synthetic invitee')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type,event_create_policy)
values ('$groupId','$ownerId','Synthetic invite race','other','member');
insert into public.group_members(group_id,user_id,role) values ('$groupId','$ownerId','owner');
insert into public.friendships(requester_user_id,addressee_user_id,status)
values ('$ownerId','$inviteeId','accepted');
set request.jwt.claim.sub='$ownerId';
set request.jwt.claim.role='authenticated';
set role authenticated;
select invitation_id from public.create_targeted_group_invitation(
 '$groupId','$inviteeId',clock_timestamp()+interval '1 day');
reset role;
"@
  $setupPath = Write-Sql 'targeted-invite-race-setup.sql' $setup
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $setupPath
  if ($LASTEXITCODE -ne 0) { throw 'synthetic setup failed' }
  $invitationId = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c "select id from public.group_targeted_invitations where group_id='$groupId' and invitee_user_id='$inviteeId' and status='pending'"
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($invitationId -join ''))) {
    throw 'synthetic invitation identifier was not created'
  }

  $groupLock = @"
begin;
select pg_advisory_xact_lock(hashtextextended('group:'||'$groupId',9010));
select pg_sleep(6);
commit;
"@
  $lockPath = Write-Sql 'targeted-invite-race-group-lock.sql' $groupLock
  $lockOut = Join-Path $tempDir 'group-lock.out'
  $lockProc = Start-Psql $lockPath $lockOut $lockApp

  $accept = @"
begin;
set local request.jwt.claim.sub='$inviteeId';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select status from public.respond_targeted_group_invitation('$invitationId',true);
commit;
"@
  $acceptPath = Write-Sql 'targeted-invite-race-accept.sql' $accept
  $acceptOut = Join-Path $tempDir 'accept.out'
  $acceptProc = Start-Psql $acceptPath $acceptOut $acceptApp

  # Synchronize on PostgreSQL state instead of timing assumptions: prove that
  # the group-lock holder owns the advisory lock and acceptance waits on it.
  $observedWait = $false
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $state = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c @"
select (
  exists (
    select 1 from pg_stat_activity a join pg_locks l on l.pid=a.pid
    where a.application_name='$lockApp' and l.locktype='advisory' and l.granted
  )
  and exists (
    select 1 from pg_stat_activity a join pg_locks l on l.pid=a.pid
    where a.application_name='$acceptApp' and a.wait_event_type='Lock'
      and l.locktype='advisory' and not l.granted
  )
)::text
"@
    if ($LASTEXITCODE -ne 0) { throw "could not inspect advisory lock state: $state" }
    if ($state.Trim() -eq 'true') { $observedWait = $true; break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $observedWait) { throw 'acceptance never reached the expected advisory-lock wait state' }

  $probe = & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -c @"
begin;
select id from public.group_targeted_invitations where id='$invitationId' for update nowait;
rollback;
"@ 2>&1
  if ($LASTEXITCODE -ne 0) { throw "invitation row was locked before group lock: $probe" }
  if (-not $lockProc.WaitForExit(15000)) {
    $lockProc.Kill()
    throw 'group lock holder exceeded 15 seconds'
  }
  if (-not $acceptProc.WaitForExit(15000)) {
    $acceptProc.Kill()
    throw 'concurrent invitation acceptance exceeded 15 seconds'
  }

  $acceptText = Get-Content -Raw $acceptOut
  if ($acceptText -notmatch 'accepted') { throw "invitee response did not commit: $acceptText" }
  $create = @"
begin;
set local request.jwt.claim.sub='$ownerId';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select invitation_id from public.create_targeted_group_invitation(
 '$groupId','$inviteeId',clock_timestamp()+interval '1 day');
commit;
"@
  $createPath = Write-Sql 'targeted-invite-race-create.sql' $create
  $createOut = Join-Path $tempDir 'create.out'
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $createPath *> $createOut
  if ($LASTEXITCODE -eq 0 -or (Get-Content -Raw $createOut) -notmatch 'invitation unavailable') {
    throw "creation after acceptance did not fail closed: $(Get-Content -Raw $createOut)"
  }
  $result = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c @"
select (select count(*) from public.group_members where group_id='$groupId' and user_id='$inviteeId')::text||':'||
       (select count(*) from public.group_targeted_invitations where group_id='$groupId' and invitee_user_id='$inviteeId' and status='accepted')::text
"@
  if ($LASTEXITCODE -ne 0 -or $result.Trim() -ne '1:1') { throw "unexpected concurrent outcome '$result'" }
  Write-Output 'PASS PostgreSQL confirmed acceptance waiting on group advisory lock while invitation row remained lockable; create after acceptance fails closed'
}
finally {
  $cleanup = @"
delete from public.groups where id='$groupId';
delete from public.friendships where requester_user_id='$ownerId' and addressee_user_id='$inviteeId';
delete from auth.users where id in ('$ownerId','$inviteeId');
"@
  $cleanupPath = Write-Sql 'targeted-invite-race-cleanup.sql' $cleanup
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $cleanupPath
  $cleanupTarget = [System.IO.Path]::GetFullPath($tempDir)
  if ($cleanupTarget -ne $resolvedTempDir -or
      -not $cleanupTarget.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      [System.IO.Path]::GetFileName($cleanupTarget) -ne "targeted-invite-race-$($groupId.Replace('-', ''))") {
    throw 'refusing to remove an unexpected temporary test directory'
  }
  Remove-Item -LiteralPath $cleanupTarget -Recurse -Force
}
