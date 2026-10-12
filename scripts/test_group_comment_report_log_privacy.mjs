import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const controllerSource = fs.readFileSync(
  path.join(root, 'apps/mobile/lib/features/groups/application/group_providers.dart'),
  'utf8',
);
const repositorySource = fs.readFileSync(
  path.join(root, 'apps/mobile/lib/features/groups/data/supabase_group_repository.dart'),
  'utf8',
);

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `missing source marker: ${startMarker}`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `missing source marker: ${endMarker}`);
  return source.slice(start, end);
}

const controllerReport = sourceBetween(
  controllerSource,
  'Future<bool> reportContent({',
  'Future<bool> _contentVoid(',
);
const controllerMutation = sourceBetween(
  controllerSource,
  'Future<bool> _contentVoid(',
  'Future<bool> searchGroupAvailability(',
);
const repositoryReport = sourceBetween(
  repositorySource,
  'Future<void> reportGroupContent({',
  'Future<GroupAvailabilityResult> findGroupAvailability(',
);
const repositoryMutation = sourceBetween(
  repositorySource,
  'Future<T> _mutate<T>(',
  'GroupSummary _group(',
);

const explicitLogSink = /\b(?:AppLogger|debugPrint|print|logger)\b|\.(?:info|warning|error|debug|log)\s*\(/i;

test('report controller passes through the shared non-logging mutation path', () => {
  assert.match(controllerReport, /_contentVoid\(/);
  assert.match(controllerReport, /_repository\.reportGroupContent\(/);
  assert.doesNotMatch(controllerReport, explicitLogSink);
});

test('success and failure handling for the controller does not log input or errors', () => {
  assert.match(controllerMutation, /await action\(\)/);
  assert.match(controllerMutation, /catch \(e\)/);
  assert.match(controllerMutation, /errorMessage: _message\(e\)/);
  assert.doesNotMatch(controllerMutation, explicitLogSink);
});

test('report repository forwards input through mutation without a logging sink', () => {
  assert.match(repositoryReport, /_mutate\('create_group_content_report'/);
  assert.match(repositoryReport, /'target_id': targetId/);
  assert.match(repositoryReport, /'reason': reason/);
  assert.match(repositoryReport, /'p_target_id': targetId/);
  assert.match(repositoryReport, /'p_reason': reason/);
  assert.doesNotMatch(repositoryReport, explicitLogSink);
});

test('shared repository mutation rethrows failures without logging request data', () => {
  assert.match(repositoryMutation, /on PostgrestException catch \(e\)/);
  assert.match(repositoryMutation, /rethrow/);
  assert.doesNotMatch(repositoryMutation, explicitLogSink);
});
