param(
  [string]$Container = 'supabase_db_phase16_fresh_20260922',
  [string]$Database = 'gpt6_duplicates_20260923'
)
$ErrorActionPreference = 'Stop'
$prefix = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
$userId = "e17a0000-0000-4000-8000-${prefix}0001"
$universityId = "e17a0000-0000-4000-8000-${prefix}0002"
$insertA = "e17a0000-0000-4000-8000-${prefix}0003"
$insertB = "e17a0000-0000-4000-8000-${prefix}0004"
$editA = "e17a0000-0000-4000-8000-${prefix}0005"
$editB = "e17a0000-0000-4000-8000-${prefix}0006"
$configKey = "duplicate-race-$prefix"
$title = "Concurrent Insert $prefix"
$editTitle = "Concurrent Edit $prefix"
$tempDir = Join-Path $env:TEMP "course-duplicate-race-$prefix"
$resolvedTempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedTempDir = [System.IO.Path]::GetFullPath($tempDir)
if (-not $resolvedTempDir.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedTempDir) -ne "course-duplicate-race-$prefix") {
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
function Start-Psql([string]$SqlPath, [string]$OutputPath) {
  return Start-Process -FilePath 'docker.exe' -ArgumentList @(
    'exec', $Container, 'psql', '-U', 'supabase_admin', '-d', $Database,
    '-X', '-v', 'ON_ERROR_STOP=1', '-f', $SqlPath
  ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError "$OutputPath.err"
}
try {
  $setup = @"
insert into auth.users(id) values ('$userId') on conflict (id) do nothing;
insert into public.universities(id,config_key,name,normalized_name,status)
values ('$universityId','$configKey','Duplicate Race $prefix','duplicaterace$prefix','active');
insert into public.course_templates(id,university_id,academic_year,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,created_by,status)
values
 ('$editA','$universityId',2026,'Concurrent Edit Seed A',public.normalize_course_text('Concurrent Edit Seed A'),'Prof Race',public.normalize_course_text('Prof Race'),1,1,'$userId','active'),
 ('$editB','$universityId',2026,'Concurrent Edit Seed B',public.normalize_course_text('Concurrent Edit Seed B'),'Prof Race',public.normalize_course_text('Prof Race'),1,1,'$userId','active');
"@
  $setupPath = Write-Sql 'duplicate-race-setup.sql' $setup
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $setupPath
  if ($LASTEXITCODE -ne 0) { throw 'setup failed' }

  $insertSqlA = @"
begin;
insert into public.course_templates(id,university_id,academic_year,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,created_by,status)
values ('$insertA','$universityId',2026,'$title',public.normalize_course_text('$title'),'Prof Race',public.normalize_course_text('Prof Race'),2,2,'$userId','active');
select pg_sleep(2.0);
commit;
"@
  $insertSqlB = @"
begin;
insert into public.course_templates(id,university_id,academic_year,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,created_by,status)
values ('$insertB','$universityId',2026,'$title',public.normalize_course_text('$title'),'Prof Race',public.normalize_course_text('Prof Race'),2,2,'$userId','active');
select pg_sleep(0.5);
commit;
"@
  $insertPathA = Write-Sql 'duplicate-race-insert-a.sql' $insertSqlA
  $insertPathB = Write-Sql 'duplicate-race-insert-b.sql' $insertSqlB
  $procA = Start-Psql $insertPathA (Join-Path $tempDir 'insert-a.out')
  Start-Sleep -Milliseconds 250
  $procB = Start-Psql $insertPathB (Join-Path $tempDir 'insert-b.out')
  $procA.WaitForExit(); $procB.WaitForExit()
  if ((Get-Item (Join-Path $tempDir 'insert-a.out')).Length -eq 0 -or
      (Get-Item (Join-Path $tempDir 'insert-b.out')).Length -eq 0 -or
      (Get-Item (Join-Path $tempDir 'insert-a.out.err')).Length -gt 0 -or
      (Get-Item (Join-Path $tempDir 'insert-b.out.err')).Length -gt 0) {
    throw "concurrent insert session returned no SQL output or an error; A=$(Get-Content -Raw (Join-Path $tempDir 'insert-a.out')); A.err=$(Get-Content -Raw (Join-Path $tempDir 'insert-a.out.err')); B=$(Get-Content -Raw (Join-Path $tempDir 'insert-b.out')); B.err=$(Get-Content -Raw (Join-Path $tempDir 'insert-b.out.err'))"
  }
  $insertCount = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.course_template_duplicate_candidates where template_a_id='$insertA' and template_b_id='$insertB' and status='pending'"
  if ($LASTEXITCODE -ne 0 -or $insertCount.Trim() -ne '1') { throw "concurrent insert expected one pending pair; got '$insertCount'" }
  Write-Output "PASS concurrent inserts: exactly one pending candidate ($insertCount)"

  $editSqlA = @"
begin;
update public.course_templates set title='$editTitle',normalized_title=public.normalize_course_text('$editTitle') where id='$editA';
select pg_sleep(2.0);
commit;
"@
  $editSqlB = @"
begin;
update public.course_templates set title='$editTitle',normalized_title=public.normalize_course_text('$editTitle') where id='$editB';
select pg_sleep(0.5);
commit;
"@
  $editPathA = Write-Sql 'duplicate-race-edit-a.sql' $editSqlA
  $editPathB = Write-Sql 'duplicate-race-edit-b.sql' $editSqlB
  $procA = Start-Psql $editPathA (Join-Path $tempDir 'edit-a.out')
  Start-Sleep -Milliseconds 250
  $procB = Start-Psql $editPathB (Join-Path $tempDir 'edit-b.out')
  $procA.WaitForExit(); $procB.WaitForExit()
  if ((Get-Item (Join-Path $tempDir 'edit-a.out')).Length -eq 0 -or
      (Get-Item (Join-Path $tempDir 'edit-b.out')).Length -eq 0 -or
      (Get-Item (Join-Path $tempDir 'edit-a.out.err')).Length -gt 0 -or
      (Get-Item (Join-Path $tempDir 'edit-b.out.err')).Length -gt 0) {
    throw 'concurrent edit session returned no SQL output or an error'
  }
  $editCount = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.course_template_duplicate_candidates where template_a_id=least('$editA'::uuid,'$editB'::uuid) and template_b_id=greatest('$editA'::uuid,'$editB'::uuid) and status='pending'"
  if ($LASTEXITCODE -ne 0 -or $editCount.Trim() -ne '1') { throw "concurrent edits expected one pending pair; got '$editCount'" }
  Write-Output "PASS concurrent edits into one cohort: exactly one pending candidate ($editCount)"

  # Multiple changes in one transaction must reconcile the final row values.
  $finalTitle = "Commit Final $prefix"
  $finalSql = @"
begin;
update public.course_templates set title='Intermediate $prefix',normalized_title=public.normalize_course_text('Intermediate $prefix') where id='$editA';
update public.course_templates set title='$finalTitle',normalized_title=public.normalize_course_text('$finalTitle') where id='$editA';
update public.course_templates set title='$finalTitle',normalized_title=public.normalize_course_text('$finalTitle') where id='$editB';
commit;
"@
  $finalPath = Write-Sql 'duplicate-race-final-state.sql' $finalSql
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $finalPath
  if ($LASTEXITCODE -ne 0) { throw 'final-state transaction failed' }
  $finalCount = & docker exec $Container psql -U supabase_admin -d $Database -X -At -v ON_ERROR_STOP=1 -c "select count(*) from public.course_template_duplicate_candidates where template_a_id=least('$editA'::uuid,'$editB'::uuid) and template_b_id=greatest('$editA'::uuid,'$editB'::uuid) and status='pending'"
  if ($LASTEXITCODE -ne 0 -or $finalCount.Trim() -ne '1') { throw "final-state reconciliation expected one pending pair; got '$finalCount'" }
  Write-Output "PASS multiple edits before commit: final-state pair retained exactly once ($finalCount)"
}
finally {
  # Remove only synthetic rows made by this run after captured assertions.
  $cleanup = @"
delete from public.course_template_duplicate_candidates where template_a_id in ('$insertA','$insertB','$editA','$editB') or template_b_id in ('$insertA','$insertB','$editA','$editB');
delete from public.course_templates where id in ('$insertA','$insertB','$editA','$editB');
delete from public.universities where id='$universityId';
delete from auth.users where id='$userId';
"@
  $cleanupPath = Write-Sql 'duplicate-race-cleanup.sql' $cleanup
  & docker exec $Container psql -U supabase_admin -d $Database -X -v ON_ERROR_STOP=1 -f $cleanupPath
  $cleanupTarget = [System.IO.Path]::GetFullPath($tempDir)
  if ($cleanupTarget -ne $resolvedTempDir -or
      -not $cleanupTarget.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      [System.IO.Path]::GetFileName($cleanupTarget) -ne "course-duplicate-race-$prefix") {
    throw 'refusing to remove an unexpected temporary test directory'
  }
  Remove-Item -LiteralPath $cleanupTarget -Recurse -Force
}
